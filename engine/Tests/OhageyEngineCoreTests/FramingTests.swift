// Unit tests for the length-prefixed framing used by the named-pipe IPC
// (decision 0006/0007).
//
// These focus on what actually breaks a byte-stream protocol: partial reads,
// several frames arriving in one read, and a hostile length prefix. XCTest
// rather than swift-testing because XCTest is the better-established of the two
// on Windows, which is the only platform that ships this engine (decision 0018).

import XCTest
@testable import OhageyEngineCore

final class FramingTests: XCTestCase {
    // MARK: - encode / decodeLength

    func testEncodePrefixesLittleEndianLength() throws {
        let payload: [UInt8] = [0xAA, 0xBB, 0xCC]
        let frame = try Framing.encode(payload)

        XCTAssertEqual(frame.count, Framing.headerLength + payload.count)
        // 3 as little-endian UInt32.
        XCTAssertEqual(Array(frame.prefix(4)), [0x03, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(frame.dropFirst(4)), payload)
    }

    func testEncodeEmptyPayload() throws {
        let frame = try Framing.encode([])
        XCTAssertEqual(frame, [0x00, 0x00, 0x00, 0x00])
    }

    func testDecodeLengthIsLittleEndian() {
        // 0x00010203 little-endian => bytes 03 02 01 00
        XCTAssertEqual(Framing.decodeLength([0x03, 0x02, 0x01, 0x00] as [UInt8]), 0x00010203)
        XCTAssertEqual(Framing.decodeLength([0xFF, 0xFF, 0xFF, 0xFF] as [UInt8]), UInt32.max)
        XCTAssertEqual(Framing.decodeLength([0x00, 0x00, 0x00, 0x00] as [UInt8]), 0)
    }

    func testEncodeRejectsOversizedPayload() {
        // Building an 8 MiB+1 array is cheap enough and exercises the real guard
        // rather than a mocked one.
        let tooBig = [UInt8](repeating: 0, count: Int(Framing.maxPayloadLength) + 1)
        XCTAssertThrowsError(try Framing.encode(tooBig)) { error in
            XCTAssertEqual(
                error as? FramingError,
                .frameTooLarge(announced: Framing.maxPayloadLength + 1,
                               limit: Framing.maxPayloadLength)
            )
        }
    }

    // MARK: - FrameDecoder round-trips

    func testRoundTripSingleFrame() throws {
        let payload: [UInt8] = Array("こんにちは".utf8)
        var decoder = FrameDecoder()
        decoder.append(try Framing.encode(payload))

        XCTAssertEqual(try decoder.nextPayload(), payload)
        XCTAssertNil(try decoder.nextPayload())
        XCTAssertTrue(decoder.isAtFrameBoundary)
    }

    func testEmptyPayloadRoundTrips() throws {
        var decoder = FrameDecoder()
        decoder.append(try Framing.encode([]))

        // An empty payload is a real frame, not "no frame" — it must come back
        // as [] and not nil, or a zero-length message would hang the reader.
        XCTAssertEqual(try decoder.nextPayload(), [])
        XCTAssertNil(try decoder.nextPayload())
    }

    // MARK: - Partial and batched reads (the reason this type exists)

    func testPartialFrameYieldsNilUntilComplete() throws {
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let frame = try Framing.encode(payload)

        var decoder = FrameDecoder()
        // Feed one byte at a time; nothing should surface until the last byte.
        for byte in frame.dropLast() {
            decoder.append([byte])
            XCTAssertNil(try decoder.nextPayload())
        }
        decoder.append([frame.last!])
        XCTAssertEqual(try decoder.nextPayload(), payload)
    }

    func testHeaderSplitAcrossReads() throws {
        let frame = try Framing.encode([0x42])

        var decoder = FrameDecoder()
        decoder.append(frame.prefix(2))          // half the length prefix
        XCTAssertNil(try decoder.nextPayload())
        decoder.append(frame.dropFirst(2))
        XCTAssertEqual(try decoder.nextPayload(), [0x42])
    }

    func testMultipleFramesInOneRead() throws {
        let first: [UInt8] = [1, 1, 1]
        let second: [UInt8] = [2, 2]
        let third: [UInt8] = []

        var decoder = FrameDecoder()
        decoder.append(try Framing.encode(first))
        decoder.append(try Framing.encode(second))
        decoder.append(try Framing.encode(third))

        XCTAssertEqual(try decoder.nextPayload(), first)
        XCTAssertEqual(try decoder.nextPayload(), second)
        XCTAssertEqual(try decoder.nextPayload(), third)
        XCTAssertNil(try decoder.nextPayload())
        XCTAssertTrue(decoder.isAtFrameBoundary)
    }

    func testTrailingPartialFrameLeavesDecoderOffBoundary() throws {
        let complete = try Framing.encode([9, 9, 9])
        let partial = try Framing.encode([7, 7, 7]).prefix(5)  // header + 1 byte

        var decoder = FrameDecoder()
        decoder.append(complete)
        decoder.append(partial)

        XCTAssertEqual(try decoder.nextPayload(), [9, 9, 9])
        XCTAssertNil(try decoder.nextPayload())
        // A client that disconnects here cut a frame in half — the server must
        // be able to tell that apart from a clean disconnect.
        XCTAssertFalse(decoder.isAtFrameBoundary)
    }

    // MARK: - Hostile input

    func testOversizedLengthPrefixThrows() {
        // Hand-craft a header claiming UInt32.max bytes without allocating them.
        var decoder = FrameDecoder()
        decoder.append([0xFF, 0xFF, 0xFF, 0xFF] as [UInt8])

        XCTAssertThrowsError(try decoder.nextPayload()) { error in
            XCTAssertEqual(
                error as? FramingError,
                .frameTooLarge(announced: UInt32.max, limit: Framing.maxPayloadLength)
            )
        }
    }

    func testLengthExactlyAtLimitIsNotRejectedByDecoder() {
        // The limit itself is legal; only above it is refused. Verified through
        // the header alone so the test does not allocate 8 MiB of payload.
        var decoder = FrameDecoder()
        let limit = Framing.maxPayloadLength
        decoder.append([
            UInt8(truncatingIfNeeded: limit),
            UInt8(truncatingIfNeeded: limit >> 8),
            UInt8(truncatingIfNeeded: limit >> 16),
            UInt8(truncatingIfNeeded: limit >> 24),
        ] as [UInt8])

        // Not enough body yet, so nil rather than a throw. (XCTAssertNil reports
        // a failure if the expression throws, which is exactly what we want.)
        XCTAssertNil(try decoder.nextPayload())
    }
}
