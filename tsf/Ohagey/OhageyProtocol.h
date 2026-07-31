// Client side of the engine IPC (decisions 0004-0007, 0031, 0032).
//
// This is Ohagey's own code, not vendored SampleIME. It replaces the sample's
// dictionary lookup with a request to the conversion server.
//
// No exceptions and no CRT surprises: this lives in a DLL loaded into every
// application the user types in, and every entry point is meant to be wrapped
// in SEH (decision 0017). Failures are reported by return value.

#pragma once

#include <windows.h>
#include <cstdint>
#include <string>
#include <vector>

namespace Ohagey
{
    // Mirrors Status.Code in ohagey.proto.
    enum class StatusCode : int32_t
    {
        Ok = 0,
        InvalidArgument = 1,
        Internal = 2,
        ModelUnavailable = 3,
    };

    // Mirrors Backend in ohagey.proto.
    enum class Backend : int32_t
    {
        Unspecified = 0,
        Cpu = 1,
        Cuda = 2,
        Vulkan = 3,
    };

    struct Segment
    {
        std::wstring text;
        std::wstring reading;
    };

    struct Candidate
    {
        std::wstring text;
        std::wstring reading;
        int32_t score = 0;
        std::vector<Segment> segments;
    };

    struct ConvertResult
    {
        std::vector<Candidate> candidates;
        // False means the engine served this from the dictionary because the
        // Zenzai model is not installed (decision 0008).
        bool zenzaiUsed = false;
    };

    struct PingResult
    {
        std::wstring engineVersion;
        bool modelLoaded = false;
        Backend backend = Backend::Unspecified;
    };

    // Why a call did not produce a result.
    //
    // `Status` means the engine answered and refused; `status`/`statusMessage`
    // carry its reason. Everything else means we never got a well-formed answer.
    enum class CallResult
    {
        Ok,
        NotConnected,
        WriteFailed,
        ReadFailed,
        // The reply did not decode, or its request_id did not match ours. Either
        // way the stream can no longer be trusted and the connection is dropped.
        BadResponse,
        Status,
    };

    // One connection to the engine. Not thread-safe: TSF is single-threaded per
    // thread manager, and each thread that needs conversion owns its own client.
    class EngineClient
    {
    public:
        EngineClient() = default;
        ~EngineClient();

        EngineClient(const EngineClient&) = delete;
        EngineClient& operator=(const EngineClient&) = delete;

        // Opens the session-scoped pipe (decision 0006). Safe to call when
        // already connected; it is a no-op then.
        bool Connect();
        void Disconnect();
        bool IsConnected() const { return _pipe != INVALID_HANDLE_VALUE; }

        // Starts the engine if it is not up, without connecting or waiting.
        //
        // Call when the text service activates. `Connect` deliberately gives
        // up ~250ms after launching rather than blocking the thread that
        // handles typing, and the engine needs a little longer than that to
        // begin listening — so the first conversion after a cold start always
        // comes back empty and only the next keystroke works. Starting the
        // engine at activation closes that gap: the seconds a user spends
        // typing a reading are more than enough, and nothing has to wait.
        //
        // Does not hold a connection. The engine exits on an idle timeout
        // measured by connections (decision 0015), so a connection opened at
        // activation and kept would stop it ever going away.
        void Warmup();

        // Each call connects on demand, so callers do not have to.
        CallResult Convert(const std::wstring& reading, uint32_t nBest,
                           const std::wstring& precedingText, ConvertResult* out);
        CallResult Commit(const std::wstring& reading, const std::wstring& text,
                          bool updateLearning);
        CallResult RegisterWord(const std::wstring& reading, const std::wstring& surface,
                                const std::wstring& partOfSpeech);
        CallResult Ping(PingResult* out);

        // Set when the last call returned CallResult::Status.
        StatusCode LastStatus() const { return _lastStatus; }
        const std::wstring& LastStatusMessage() const { return _lastStatusMessage; }

        // `\\.\pipe\ohagey_session_<id>` for the current Windows session.
        // Session-scoped so concurrent interactive sessions never share an
        // engine or its learning data (decision 0006).
        static bool PipeName(std::wstring* out);

        // Full path to OhageyEngine.exe: the directory this DLL was loaded
        // from (decision 0033). Returns false if it cannot be determined.
        static bool EnginePath(std::wstring* out);

    private:
        // Sends one framed request and reads the framed reply.
        CallResult Exchange(const std::vector<uint8_t>& payload, uint32_t requestId,
                            std::vector<uint8_t>* reply);
        bool WriteAll(const uint8_t* data, size_t size);
        bool ReadAll(uint8_t* data, size_t size);

        // Starts the engine if nothing is listening (decisions 0015 / 0033).
        // Returns true if a launch was attempted, false if it was skipped
        // because one was attempted too recently.
        bool LaunchEngine();

        HANDLE _pipe = INVALID_HANDLE_VALUE;
        uint32_t _nextRequestId = 1;
        StatusCode _lastStatus = StatusCode::Ok;
        std::wstring _lastStatusMessage;

        // When the last launch was attempted, from GetTickCount64. An engine
        // that dies on startup would otherwise get a fresh process per
        // keystroke.
        uint64_t _lastLaunchTick = 0;
    };
}
