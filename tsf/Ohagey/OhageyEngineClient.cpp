// Named-pipe client for the conversion engine (decisions 0006 / 0007 / 0031).

#include "OhageyProtocol.h"
#include "OhageyWire.h"

#include <sddl.h>

namespace Ohagey
{
    namespace
    {
        // Field numbers from ohagey.proto. Hand-kept in step with it (0032).
        namespace RequestField
        {
            enum { RequestId = 1, Convert = 2, Commit = 3, RegisterWord = 4, Ping = 5 };
        }
        namespace ResponseField
        {
            enum { RequestId = 1, Status = 2, Convert = 3, Commit = 4, RegisterWord = 5, Ping = 6 };
        }

        // A conversion request is a reading plus context; nothing legitimate is
        // anywhere near this. Matches Framing.maxPayloadLength on the engine.
        const uint32_t kMaxPayload = 8 * 1024 * 1024;

        const DWORD kFrameHeaderSize = 4;

        // Exactly the rights the engine's ACL grants a client (decision 0031).
        //
        // NOT GENERIC_READ | GENERIC_WRITE: on a pipe GENERIC_WRITE expands to
        // include FILE_CREATE_PIPE_INSTANCE, which the engine deliberately
        // withholds from sandboxed clients, and the access check demands every
        // requested right. Asking for the generic pair makes this fail from an
        // AppContainer (UWP) app.
        const DWORD kClientAccess =
            FILE_READ_DATA | FILE_WRITE_DATA |
            FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES |
            SYNCHRONIZE;

        void PutFrameHeader(std::vector<uint8_t>& frame, uint32_t length)
        {
            // Little-endian, matching Framing.swift. Written byte by byte
            // rather than memcpy'ing a uint32 so the format does not depend on
            // this machine's endianness.
            frame.push_back(static_cast<uint8_t>(length));
            frame.push_back(static_cast<uint8_t>(length >> 8));
            frame.push_back(static_cast<uint8_t>(length >> 16));
            frame.push_back(static_cast<uint8_t>(length >> 24));
        }

        uint32_t ReadFrameHeader(const uint8_t* header)
        {
            return static_cast<uint32_t>(header[0])
                 | (static_cast<uint32_t>(header[1]) << 8)
                 | (static_cast<uint32_t>(header[2]) << 16)
                 | (static_cast<uint32_t>(header[3]) << 24);
        }
    }

    EngineClient::~EngineClient()
    {
        Disconnect();
    }

    bool EngineClient::PipeName(std::wstring* out)
    {
        DWORD sessionId = 0;
        if (!ProcessIdToSessionId(GetCurrentProcessId(), &sessionId))
        {
            return false;
        }

        wchar_t buffer[64] = {};
        const int written = swprintf_s(buffer, L"\\\\.\\pipe\\ohagey_session_%lu", sessionId);
        if (written < 0) return false;

        out->assign(buffer);
        return true;
    }

    bool EngineClient::Connect()
    {
        if (IsConnected()) return true;

        std::wstring name;
        if (!PipeName(&name)) return false;

        // The server creates the next instance right after accepting, so the
        // only window where none is free is that handoff. ERROR_PIPE_BUSY is
        // therefore expected occasionally and worth one wait, not a failure.
        for (int attempt = 0; attempt < 2; ++attempt)
        {
            _pipe = CreateFileW(name.c_str(), kClientAccess, 0, nullptr,
                                OPEN_EXISTING, 0, nullptr);
            if (_pipe != INVALID_HANDLE_VALUE) return true;

            if (GetLastError() != ERROR_PIPE_BUSY) break;
            if (!WaitNamedPipeW(name.c_str(), 1000)) break;
        }

        _pipe = INVALID_HANDLE_VALUE;
        // TODO (decision 0015): when the engine is not running at all
        // (ERROR_FILE_NOT_FOUND) the client is supposed to launch it. That
        // needs the installed location, which the installer layout has not
        // fixed yet (phase 3).
        return false;
    }

    void EngineClient::Disconnect()
    {
        if (_pipe != INVALID_HANDLE_VALUE)
        {
            CloseHandle(_pipe);
            _pipe = INVALID_HANDLE_VALUE;
        }
    }

    bool EngineClient::WriteAll(const uint8_t* data, size_t size)
    {
        size_t offset = 0;
        while (offset < size)
        {
            DWORD written = 0;
            if (!WriteFile(_pipe, data + offset, static_cast<DWORD>(size - offset), &written, nullptr)
                || written == 0)
            {
                return false;
            }
            offset += written;
        }
        return true;
    }

    bool EngineClient::ReadAll(uint8_t* data, size_t size)
    {
        size_t offset = 0;
        while (offset < size)
        {
            DWORD read = 0;
            if (!ReadFile(_pipe, data + offset, static_cast<DWORD>(size - offset), &read, nullptr)
                || read == 0)
            {
                return false;
            }
            offset += read;
        }
        return true;
    }

    CallResult EngineClient::Exchange(const std::vector<uint8_t>& payload, uint32_t requestId,
                                      std::vector<uint8_t>* reply)
    {
        if (!Connect()) return CallResult::NotConnected;

        std::vector<uint8_t> frame;
        frame.reserve(kFrameHeaderSize + payload.size());
        PutFrameHeader(frame, static_cast<uint32_t>(payload.size()));
        frame.insert(frame.end(), payload.begin(), payload.end());

        if (!WriteAll(frame.data(), frame.size()))
        {
            // A broken pipe usually means the engine exited on its idle timeout
            // (decision 0015). Drop the handle so the next call reconnects
            // rather than reusing a dead one.
            Disconnect();
            return CallResult::WriteFailed;
        }

        uint8_t header[kFrameHeaderSize] = {};
        if (!ReadAll(header, sizeof(header)))
        {
            Disconnect();
            return CallResult::ReadFailed;
        }

        const uint32_t length = ReadFrameHeader(header);
        if (length > kMaxPayload)
        {
            // We cannot find where the next frame starts, so there is nothing
            // to resynchronise to (decision 0030).
            Disconnect();
            return CallResult::BadResponse;
        }

        reply->assign(length, 0);
        if (length > 0 && !ReadAll(reply->data(), length))
        {
            Disconnect();
            return CallResult::ReadFailed;
        }

        // Correlate before the caller sees anything: a reply under the wrong id
        // would be another request's answer, and silently accepting it is how a
        // user ends up with someone else's text.
        Wire::Reader reader(reply->data(), reply->size());
        uint32_t replyId = 0;
        bool sawId = false;
        while (!reader.AtEnd())
        {
            uint32_t field = 0;
            Wire::WireType type = Wire::Varint;
            if (!reader.ReadTag(&field, &type)) break;
            if (field == ResponseField::RequestId && type == Wire::Varint)
            {
                if (!reader.ReadUInt32(&replyId)) break;
                sawId = true;
                break;
            }
            if (!reader.SkipField(type)) break;
        }
        if (!reader.Ok() || !sawId || replyId != requestId)
        {
            Disconnect();
            return CallResult::BadResponse;
        }

        return CallResult::Ok;
    }

    namespace
    {
        // Reads the Status message and reports whether the call succeeded.
        bool ParseStatus(const uint8_t* data, size_t size, StatusCode* code, std::wstring* message)
        {
            Wire::Reader reader(data, size);
            // proto3 omits CODE_OK, so an absent field means success.
            *code = StatusCode::Ok;
            message->clear();

            while (!reader.AtEnd())
            {
                uint32_t field = 0;
                Wire::WireType type = Wire::Varint;
                if (!reader.ReadTag(&field, &type)) return false;

                if (field == 1 && type == Wire::Varint)
                {
                    int32_t raw = 0;
                    if (!reader.ReadInt32(&raw)) return false;
                    *code = static_cast<StatusCode>(raw);
                }
                else if (field == 2 && type == Wire::LengthDelimited)
                {
                    if (!reader.ReadString(message)) return false;
                }
                else if (!reader.SkipField(type))
                {
                    return false;
                }
            }
            return reader.Ok();
        }

        bool ParseSegment(const uint8_t* data, size_t size, Segment* out)
        {
            Wire::Reader reader(data, size);
            while (!reader.AtEnd())
            {
                uint32_t field = 0;
                Wire::WireType type = Wire::Varint;
                if (!reader.ReadTag(&field, &type)) return false;

                if (field == 1 && type == Wire::LengthDelimited)
                {
                    if (!reader.ReadString(&out->text)) return false;
                }
                else if (field == 2 && type == Wire::LengthDelimited)
                {
                    if (!reader.ReadString(&out->reading)) return false;
                }
                else if (!reader.SkipField(type))
                {
                    return false;
                }
            }
            return reader.Ok();
        }

        bool ParseCandidate(const uint8_t* data, size_t size, Candidate* out)
        {
            Wire::Reader reader(data, size);
            while (!reader.AtEnd())
            {
                uint32_t field = 0;
                Wire::WireType type = Wire::Varint;
                if (!reader.ReadTag(&field, &type)) return false;

                if (field == 1 && type == Wire::LengthDelimited)
                {
                    if (!reader.ReadString(&out->text)) return false;
                }
                else if (field == 2 && type == Wire::LengthDelimited)
                {
                    if (!reader.ReadString(&out->reading)) return false;
                }
                else if (field == 3 && type == Wire::Varint)
                {
                    if (!reader.ReadInt32(&out->score)) return false;
                }
                else if (field == 4 && type == Wire::LengthDelimited)
                {
                    const uint8_t* body = nullptr;
                    size_t bodySize = 0;
                    if (!reader.ReadMessage(&body, &bodySize)) return false;
                    Segment segment;
                    if (!ParseSegment(body, bodySize, &segment)) return false;
                    out->segments.push_back(segment);
                }
                else if (!reader.SkipField(type))
                {
                    return false;
                }
            }
            return reader.Ok();
        }

        bool ParseConvertResponse(const uint8_t* data, size_t size, ConvertResult* out)
        {
            Wire::Reader reader(data, size);
            while (!reader.AtEnd())
            {
                uint32_t field = 0;
                Wire::WireType type = Wire::Varint;
                if (!reader.ReadTag(&field, &type)) return false;

                if (field == 1 && type == Wire::LengthDelimited)
                {
                    const uint8_t* body = nullptr;
                    size_t bodySize = 0;
                    if (!reader.ReadMessage(&body, &bodySize)) return false;
                    Candidate candidate;
                    if (!ParseCandidate(body, bodySize, &candidate)) return false;
                    out->candidates.push_back(candidate);
                }
                else if (field == 2 && type == Wire::Varint)
                {
                    if (!reader.ReadBool(&out->zenzaiUsed)) return false;
                }
                else if (!reader.SkipField(type))
                {
                    return false;
                }
            }
            return reader.Ok();
        }

        bool ParsePingResponse(const uint8_t* data, size_t size, PingResult* out)
        {
            Wire::Reader reader(data, size);
            while (!reader.AtEnd())
            {
                uint32_t field = 0;
                Wire::WireType type = Wire::Varint;
                if (!reader.ReadTag(&field, &type)) return false;

                if (field == 1 && type == Wire::LengthDelimited)
                {
                    if (!reader.ReadString(&out->engineVersion)) return false;
                }
                else if (field == 2 && type == Wire::Varint)
                {
                    if (!reader.ReadBool(&out->modelLoaded)) return false;
                }
                else if (field == 3 && type == Wire::Varint)
                {
                    int32_t raw = 0;
                    if (!reader.ReadInt32(&raw)) return false;
                    out->backend = static_cast<Backend>(raw);
                }
                else if (!reader.SkipField(type))
                {
                    return false;
                }
            }
            return reader.Ok();
        }
    }

    // Walks a Response, checking status and handing the matching body to
    // `parseBody`. `bodyField` is the oneof case this call expects.
    namespace
    {
        template <typename ParseBody>
        CallResult ReadResponse(const std::vector<uint8_t>& reply, uint32_t bodyField,
                                StatusCode* status, std::wstring* statusMessage,
                                ParseBody parseBody)
        {
            Wire::Reader reader(reply.data(), reply.size());
            bool sawBody = false;

            while (!reader.AtEnd())
            {
                uint32_t field = 0;
                Wire::WireType type = Wire::Varint;
                if (!reader.ReadTag(&field, &type)) return CallResult::BadResponse;

                if (field == ResponseField::Status && type == Wire::LengthDelimited)
                {
                    const uint8_t* body = nullptr;
                    size_t bodySize = 0;
                    if (!reader.ReadMessage(&body, &bodySize)) return CallResult::BadResponse;
                    if (!ParseStatus(body, bodySize, status, statusMessage)) return CallResult::BadResponse;
                }
                else if (field == bodyField && type == Wire::LengthDelimited)
                {
                    const uint8_t* body = nullptr;
                    size_t bodySize = 0;
                    if (!reader.ReadMessage(&body, &bodySize)) return CallResult::BadResponse;
                    if (!parseBody(body, bodySize)) return CallResult::BadResponse;
                    sawBody = true;
                }
                else if (!reader.SkipField(type))
                {
                    return CallResult::BadResponse;
                }
            }
            if (!reader.Ok()) return CallResult::BadResponse;

            // A failure carries status only and no body, by design: the client
            // decides success from status.code, not from which oneof arrived
            // (decision 0030).
            if (*status != StatusCode::Ok) return CallResult::Status;
            if (!sawBody) return CallResult::BadResponse;
            return CallResult::Ok;
        }
    }

    CallResult EngineClient::Convert(const std::wstring& reading, uint32_t nBest,
                                     const std::wstring& precedingText, ConvertResult* out)
    {
        std::vector<uint8_t> convert;
        Wire::WriteString(convert, 1, reading);
        Wire::WriteUInt32(convert, 2, nBest);
        if (!precedingText.empty())
        {
            std::vector<uint8_t> context;
            Wire::WriteString(context, 1, precedingText);
            Wire::WriteMessage(convert, 3, context);
        }

        const uint32_t requestId = _nextRequestId++;
        std::vector<uint8_t> request;
        Wire::WriteUInt32(request, RequestField::RequestId, requestId);
        Wire::WriteMessage(request, RequestField::Convert, convert);

        std::vector<uint8_t> reply;
        const CallResult exchanged = Exchange(request, requestId, &reply);
        if (exchanged != CallResult::Ok) return exchanged;

        *out = ConvertResult();
        return ReadResponse(reply, ResponseField::Convert, &_lastStatus, &_lastStatusMessage,
                            [out](const uint8_t* data, size_t size)
                            {
                                return ParseConvertResponse(data, size, out);
                            });
    }

    CallResult EngineClient::Commit(const std::wstring& reading, const std::wstring& text,
                                    bool updateLearning)
    {
        std::vector<uint8_t> commit;
        Wire::WriteString(commit, 1, reading);
        Wire::WriteString(commit, 2, text);
        Wire::WriteBool(commit, 3, updateLearning);

        const uint32_t requestId = _nextRequestId++;
        std::vector<uint8_t> request;
        Wire::WriteUInt32(request, RequestField::RequestId, requestId);
        Wire::WriteMessage(request, RequestField::Commit, commit);

        std::vector<uint8_t> reply;
        const CallResult exchanged = Exchange(request, requestId, &reply);
        if (exchanged != CallResult::Ok) return exchanged;

        return ReadResponse(reply, ResponseField::Commit, &_lastStatus, &_lastStatusMessage,
                            [](const uint8_t*, size_t) { return true; });
    }

    CallResult EngineClient::RegisterWord(const std::wstring& reading, const std::wstring& surface,
                                          const std::wstring& partOfSpeech)
    {
        std::vector<uint8_t> registerWord;
        Wire::WriteString(registerWord, 1, reading);
        Wire::WriteString(registerWord, 2, surface);
        Wire::WriteString(registerWord, 3, partOfSpeech);

        const uint32_t requestId = _nextRequestId++;
        std::vector<uint8_t> request;
        Wire::WriteUInt32(request, RequestField::RequestId, requestId);
        Wire::WriteMessage(request, RequestField::RegisterWord, registerWord);

        std::vector<uint8_t> reply;
        const CallResult exchanged = Exchange(request, requestId, &reply);
        if (exchanged != CallResult::Ok) return exchanged;

        return ReadResponse(reply, ResponseField::RegisterWord, &_lastStatus, &_lastStatusMessage,
                            [](const uint8_t*, size_t) { return true; });
    }

    CallResult EngineClient::Ping(PingResult* out)
    {
        const uint32_t requestId = _nextRequestId++;
        std::vector<uint8_t> request;
        Wire::WriteUInt32(request, RequestField::RequestId, requestId);
        // PingRequest has no fields, but the oneof case still has to be present
        // or the engine sees no request kind at all.
        Wire::WriteMessage(request, RequestField::Ping, std::vector<uint8_t>());

        std::vector<uint8_t> reply;
        const CallResult exchanged = Exchange(request, requestId, &reply);
        if (exchanged != CallResult::Ok) return exchanged;

        *out = PingResult();
        return ReadResponse(reply, ResponseField::Ping, &_lastStatus, &_lastStatusMessage,
                            [out](const uint8_t* data, size_t size)
                            {
                                return ParsePingResponse(data, size, out);
                            });
    }
}
