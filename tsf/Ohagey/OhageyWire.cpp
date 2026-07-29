// See OhageyWire.h. Hand-written for ohagey.proto only (decision 0032).

#include "OhageyWire.h"

#include <windows.h>

namespace Ohagey { namespace Wire
{
    // ── Writing ─────────────────────────────────────────────────────────────

    void WriteVarint(std::vector<uint8_t>& buf, uint64_t value)
    {
        while (value >= 0x80)
        {
            buf.push_back(static_cast<uint8_t>(value) | 0x80);
            value >>= 7;
        }
        buf.push_back(static_cast<uint8_t>(value));
    }

    void WriteTag(std::vector<uint8_t>& buf, uint32_t field, WireType type)
    {
        WriteVarint(buf, (static_cast<uint64_t>(field) << 3) | static_cast<uint64_t>(type));
    }

    void WriteUInt32(std::vector<uint8_t>& buf, uint32_t field, uint32_t value)
    {
        if (value == 0) return;
        WriteTag(buf, field, Varint);
        WriteVarint(buf, value);
    }

    void WriteInt32(std::vector<uint8_t>& buf, uint32_t field, int32_t value)
    {
        if (value == 0) return;
        WriteTag(buf, field, Varint);
        // proto3 sign-extends int32 to 64 bits on the wire, so a negative value
        // is ten bytes. Casting through uint32 first would encode a different
        // number entirely.
        WriteVarint(buf, static_cast<uint64_t>(static_cast<int64_t>(value)));
    }

    void WriteBool(std::vector<uint8_t>& buf, uint32_t field, bool value)
    {
        if (!value) return;
        WriteTag(buf, field, Varint);
        WriteVarint(buf, 1);
    }

    void WriteString(std::vector<uint8_t>& buf, uint32_t field, const std::wstring& value)
    {
        if (value.empty()) return;
        const std::string utf8 = ToUtf8(value);
        WriteTag(buf, field, LengthDelimited);
        WriteVarint(buf, utf8.size());
        buf.insert(buf.end(), utf8.begin(), utf8.end());
    }

    void WriteMessage(std::vector<uint8_t>& buf, uint32_t field, const std::vector<uint8_t>& body)
    {
        WriteTag(buf, field, LengthDelimited);
        WriteVarint(buf, body.size());
        buf.insert(buf.end(), body.begin(), body.end());
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    bool Reader::Require(size_t bytes)
    {
        if (!_ok) return false;
        if (static_cast<size_t>(_end - _p) < bytes)
        {
            _ok = false;
            return false;
        }
        return true;
    }

    bool Reader::ReadVarint(uint64_t* value)
    {
        if (!_ok) return false;

        uint64_t result = 0;
        for (int shift = 0; shift < 64; shift += 7)
        {
            if (!Require(1)) return false;
            const uint8_t byte = *_p++;
            result |= static_cast<uint64_t>(byte & 0x7F) << shift;
            if ((byte & 0x80) == 0)
            {
                *value = result;
                return true;
            }
        }
        // More than ten continuation bytes: not a varint we will ever produce,
        // and continuing would silently truncate.
        _ok = false;
        return false;
    }

    bool Reader::ReadTag(uint32_t* field, WireType* type)
    {
        uint64_t tag = 0;
        if (!ReadVarint(&tag)) return false;

        const uint32_t number = static_cast<uint32_t>(tag >> 3);
        const uint32_t wire = static_cast<uint32_t>(tag & 0x07);
        // Field 0 is not legal, and wire types 6/7 do not exist.
        if (number == 0 || wire > 5)
        {
            _ok = false;
            return false;
        }
        *field = number;
        *type = static_cast<WireType>(wire);
        return true;
    }

    bool Reader::ReadUInt32(uint32_t* value)
    {
        uint64_t raw = 0;
        if (!ReadVarint(&raw)) return false;
        *value = static_cast<uint32_t>(raw);
        return true;
    }

    bool Reader::ReadInt32(int32_t* value)
    {
        uint64_t raw = 0;
        if (!ReadVarint(&raw)) return false;
        // Negative int32 arrives sign-extended to 64 bits; truncating to 32 is
        // what recovers the original value.
        *value = static_cast<int32_t>(static_cast<uint32_t>(raw));
        return true;
    }

    bool Reader::ReadBool(bool* value)
    {
        uint64_t raw = 0;
        if (!ReadVarint(&raw)) return false;
        *value = (raw != 0);
        return true;
    }

    bool Reader::ReadString(std::wstring* value)
    {
        uint64_t size = 0;
        if (!ReadVarint(&size)) return false;
        if (size > static_cast<uint64_t>(_end - _p))
        {
            _ok = false;
            return false;
        }
        *value = FromUtf8(reinterpret_cast<const char*>(_p), static_cast<size_t>(size));
        _p += size;
        return true;
    }

    bool Reader::ReadMessage(const uint8_t** data, size_t* size)
    {
        uint64_t length = 0;
        if (!ReadVarint(&length)) return false;
        if (length > static_cast<uint64_t>(_end - _p))
        {
            _ok = false;
            return false;
        }
        *data = _p;
        *size = static_cast<size_t>(length);
        _p += length;
        return true;
    }

    bool Reader::SkipField(WireType type)
    {
        switch (type)
        {
        case Varint:
        {
            uint64_t ignored = 0;
            return ReadVarint(&ignored);
        }
        case Fixed64:
            if (!Require(8)) return false;
            _p += 8;
            return true;
        case LengthDelimited:
        {
            const uint8_t* data = nullptr;
            size_t size = 0;
            return ReadMessage(&data, &size);
        }
        case Fixed32:
            if (!Require(4)) return false;
            _p += 4;
            return true;
        case StartGroup:
        case EndGroup:
        default:
            // Groups are deprecated and our schema never emits them. Skipping
            // one correctly means matching end tags; refusing is honest and
            // keeps us from guessing at a stream we cannot resynchronise.
            _ok = false;
            return false;
        }
    }

    // ── UTF-8 <-> UTF-16 ────────────────────────────────────────────────────

    std::string ToUtf8(const std::wstring& value)
    {
        if (value.empty()) return std::string();

        const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                             static_cast<int>(value.size()),
                                             nullptr, 0, nullptr, nullptr);
        if (size <= 0) return std::string();

        std::string utf8(static_cast<size_t>(size), '\0');
        WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                            &utf8[0], size, nullptr, nullptr);
        return utf8;
    }

    std::wstring FromUtf8(const char* data, size_t size)
    {
        if (size == 0) return std::wstring();

        const int count = MultiByteToWideChar(CP_UTF8, 0, data, static_cast<int>(size), nullptr, 0);
        if (count <= 0) return std::wstring();

        std::wstring wide(static_cast<size_t>(count), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, data, static_cast<int>(size), &wide[0], count);
        return wide;
    }
}}
