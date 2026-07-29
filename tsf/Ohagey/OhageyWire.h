// Protobuf wire format, hand-written for ohagey.proto only (decision 0032).
//
// ⚠️ THIS IS NOT GENERATED. If ohagey.proto changes, change this by hand.
// The engine side *is* generated (swift-protobuf), so a mismatch shows up as a
// failing round trip against a real engine rather than as a compile error.
//
// Only what the schema actually needs: varint and length-delimited fields.
// No groups, no maps, no packed repeated, no fixed32/64 payload fields.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace Ohagey { namespace Wire
{
    enum WireType : uint32_t
    {
        Varint = 0,
        Fixed64 = 1,
        LengthDelimited = 2,
        StartGroup = 3,   // not produced by our schema; only skipped
        EndGroup = 4,
        Fixed32 = 5,
    };

    // ── Writing ─────────────────────────────────────────────────────────────

    void WriteVarint(std::vector<uint8_t>& buf, uint64_t value);
    void WriteTag(std::vector<uint8_t>& buf, uint32_t field, WireType type);

    // proto3 omits fields at their default value, and the engine relies on that
    // to tell "absent" from "explicitly zero" where it matters. These skip
    // zero/false/empty accordingly.
    void WriteUInt32(std::vector<uint8_t>& buf, uint32_t field, uint32_t value);
    void WriteInt32(std::vector<uint8_t>& buf, uint32_t field, int32_t value);
    void WriteBool(std::vector<uint8_t>& buf, uint32_t field, bool value);
    void WriteString(std::vector<uint8_t>& buf, uint32_t field, const std::wstring& value);
    // Nested messages are always written, even when empty: an empty message is
    // how `PingRequest{}` and the oneof cases with no fields are expressed.
    void WriteMessage(std::vector<uint8_t>& buf, uint32_t field, const std::vector<uint8_t>& body);

    // ── Reading ─────────────────────────────────────────────────────────────

    // Walks one message. Construction does not validate; every read reports
    // failure through `Ok()`, and a reader that has failed stays failed.
    class Reader
    {
    public:
        Reader(const uint8_t* data, size_t size) : _p(data), _end(data + size) {}

        bool Ok() const { return _ok; }
        bool AtEnd() const { return _p >= _end; }

        // Reads the next field's number and wire type.
        bool ReadTag(uint32_t* field, WireType* type);

        bool ReadVarint(uint64_t* value);
        bool ReadUInt32(uint32_t* value);
        bool ReadInt32(int32_t* value);
        bool ReadBool(bool* value);
        bool ReadString(std::wstring* value);
        // Returns a view of the nested message body; it stays valid as long as
        // the buffer this reader was built over does.
        bool ReadMessage(const uint8_t** data, size_t* size);

        // Advances past a field this build does not know about. Without this a
        // newer engine's reply would be unreadable rather than merely
        // incomplete — the whole point of being forward compatible.
        bool SkipField(WireType type);

    private:
        bool Require(size_t bytes);

        const uint8_t* _p;
        const uint8_t* _end;
        bool _ok = true;
    };

    // ── UTF-8 <-> UTF-16 ────────────────────────────────────────────────────
    // The wire is UTF-8 (protobuf `string`); TSF speaks UTF-16.

    std::string ToUtf8(const std::wstring& value);
    std::wstring FromUtf8(const char* data, size_t size);
}}
