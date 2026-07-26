// Length-prefixed framing for the named-pipe IPC (decision 0006/0007).
//
// A named pipe in byte mode is a stream and Protobuf messages are not
// self-delimiting, so every message is framed as:
//
//     [ 4-byte little-endian UInt32 payload length ][ payload bytes ]
//
// This file is deliberately free of Windows and Protobuf dependencies so the
// framing logic stays portable and unit-testable on any platform.

import Foundation

public enum FramingError: Error, Equatable {
    /// Peer announced a frame larger than `Framing.maxPayloadLength`. The
    /// connection must be dropped: we can no longer find the next boundary.
    case frameTooLarge(announced: UInt32, limit: UInt32)
    /// The stream ended in the middle of a frame.
    case truncated
}

public enum Framing {
    /// Header is a fixed 4-byte little-endian length.
    public static let headerLength = 4

    /// Upper bound on a single payload. Guards against a corrupt or hostile
    /// length prefix causing an unbounded allocation. Conversion requests are
    /// small (a reading plus context); 8 MiB is far above any legitimate frame.
    public static let maxPayloadLength: UInt32 = 8 * 1024 * 1024

    /// Prefixes `payload` with its little-endian length.
    public static func encode(_ payload: [UInt8]) throws -> [UInt8] {
        let count = UInt32(payload.count)
        guard count <= maxPayloadLength else {
            throw FramingError.frameTooLarge(announced: count, limit: maxPayloadLength)
        }
        var frame = [UInt8]()
        frame.reserveCapacity(headerLength + payload.count)
        frame.append(UInt8(truncatingIfNeeded: count))
        frame.append(UInt8(truncatingIfNeeded: count >> 8))
        frame.append(UInt8(truncatingIfNeeded: count >> 16))
        frame.append(UInt8(truncatingIfNeeded: count >> 24))
        frame.append(contentsOf: payload)
        return frame
    }

    /// Reads a 4-byte little-endian length from the start of `header`.
    /// `header` must contain at least `headerLength` bytes.
    public static func decodeLength<C: Collection>(_ header: C) -> UInt32
    where C.Element == UInt8 {
        var iterator = header.makeIterator()
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            guard let byte = iterator.next() else { break }
            value |= UInt32(byte) << UInt32(shift)
        }
        return value
    }
}

/// Incremental frame reassembler.
///
/// A single `ReadFile` on a pipe may return a partial frame, or several frames
/// at once. Feed every chunk read from the pipe into `append(_:)` and drain
/// whole payloads with `nextPayload()` until it returns nil.
public struct FrameDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append<C: Sequence>(_ bytes: C) where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete payload, or nil if more bytes are needed.
    /// Throws `FramingError.frameTooLarge` when the announced length exceeds
    /// the limit — the caller must then close the connection rather than retry,
    /// because the stream can no longer be resynchronized.
    public mutating func nextPayload() throws -> [UInt8]? {
        guard buffer.count >= Framing.headerLength else { return nil }
        let length = Framing.decodeLength(buffer.prefix(Framing.headerLength))
        guard length <= Framing.maxPayloadLength else {
            throw FramingError.frameTooLarge(announced: length, limit: Framing.maxPayloadLength)
        }
        let total = Framing.headerLength + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = Array(buffer[Framing.headerLength ..< total])
        buffer.removeFirst(total)
        return payload
    }

    /// True when no partial frame is pending. Used to distinguish a clean
    /// client disconnect from one that cut a frame in half.
    public var isAtFrameBoundary: Bool { buffer.isEmpty }
}
