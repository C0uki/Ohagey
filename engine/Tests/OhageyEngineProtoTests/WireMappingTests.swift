// Tests for the wire <-> engine model mapping (decision 0007).
//
// This layer is the engine's trust boundary: everything on its input side came
// off a named pipe that any process in the session can open. The cases worth
// pinning down are the ones where a wire value has no equivalent in the engine
// model — an absent oneof, the `n_best == 0` sentinel, a count large enough to
// be an attack — plus request-ID correlation, which a pipelining client relies
// on to match replies to requests.

import XCTest
@testable import OhageyEngineProto
import OhageyEngineCore

final class WireRequestDecodingTests: XCTestCase {
    // MARK: - Convert

    func testConvertRequestMapsAllFields() throws {
        var convert = Ohagey_Ipc_V1_ConvertRequest()
        convert.reading = "へんかん"
        convert.nBest = 5
        convert.context.precedingText = "きょうは"

        let decoded = try decode(kind: .convert(convert), requestID: 42)

        XCTAssertEqual(decoded.requestID, 42)
        XCTAssertEqual(decoded.body, .convert(reading: "へんかん", nBest: 5, precedingText: "きょうは"))
    }

    func testMissingContextBecomesEmptyPrecedingText() throws {
        var convert = Ohagey_Ipc_V1_ConvertRequest()
        convert.reading = "あ"
        // `context` never set: proto3 message fields read back as a default
        // instance, which must not trap or produce a bogus value.

        let decoded = try decode(kind: .convert(convert))

        XCTAssertEqual(decoded.body, .convert(reading: "あ", nBest: EngineLimits.defaultCandidateCount, precedingText: ""))
    }

    func testZeroNBestResolvesToEngineDefault() {
        XCTAssertEqual(WireCodec.resolveCandidateCount(0), EngineLimits.defaultCandidateCount)
    }

    func testOversizedNBestIsClamped() {
        XCTAssertEqual(WireCodec.resolveCandidateCount(.max), EngineLimits.maxCandidateCount)
        XCTAssertEqual(
            WireCodec.resolveCandidateCount(UInt32(EngineLimits.maxCandidateCount) + 1),
            EngineLimits.maxCandidateCount
        )
    }

    func testNBestAtLimitIsNotClamped() {
        XCTAssertEqual(
            WireCodec.resolveCandidateCount(UInt32(EngineLimits.maxCandidateCount)),
            EngineLimits.maxCandidateCount
        )
    }

    func testEmptyReadingIsRejected() throws {
        let decoded = try? decode(kind: .convert(Ohagey_Ipc_V1_ConvertRequest()))
        XCTAssertNil(decoded)
    }

    // MARK: - Commit

    func testCommitRequestMapsAllFields() throws {
        var commit = Ohagey_Ipc_V1_CommitRequest()
        commit.reading = "へんかん"
        commit.text = "変換"
        commit.updateLearning = true

        let decoded = try decode(kind: .commit(commit))

        XCTAssertEqual(decoded.body, .commit(reading: "へんかん", text: "変換", updateLearning: true))
    }

    func testCommitWithEmptyTextIsRejected() {
        var commit = Ohagey_Ipc_V1_CommitRequest()
        commit.reading = "へんかん"

        XCTAssertThrowsError(try decode(kind: .commit(commit)))
    }

    /// The learning store is keyed by reading, so an empty key would poison it.
    func testCommitWithoutReadingIsRejectedOnlyWhenItWouldLearn() throws {
        var learning = Ohagey_Ipc_V1_CommitRequest()
        learning.text = "変換"
        learning.updateLearning = true
        XCTAssertThrowsError(try decode(kind: .commit(learning)))

        var notLearning = learning
        notLearning.updateLearning = false
        let decoded = try decode(kind: .commit(notLearning))
        XCTAssertEqual(decoded.body, .commit(reading: "", text: "変換", updateLearning: false))
    }

    // MARK: - Register word

    func testRegisterWordMapsAllFields() throws {
        var register = Ohagey_Ipc_V1_RegisterWordRequest()
        register.reading = "おはぎー"
        register.surface = "Ohagey"
        register.partOfSpeech = "名詞"

        let decoded = try decode(kind: .registerWord(register))

        XCTAssertEqual(decoded.body, .registerWord(reading: "おはぎー", surface: "Ohagey", partOfSpeech: "名詞"))
    }

    /// part_of_speech is documented as an optional hint.
    func testRegisterWordWithoutPartOfSpeechIsAccepted() throws {
        var register = Ohagey_Ipc_V1_RegisterWordRequest()
        register.reading = "おはぎー"
        register.surface = "Ohagey"

        let decoded = try decode(kind: .registerWord(register))

        XCTAssertEqual(decoded.body, .registerWord(reading: "おはぎー", surface: "Ohagey", partOfSpeech: ""))
    }

    func testRegisterWordRequiresReadingAndSurface() {
        var noReading = Ohagey_Ipc_V1_RegisterWordRequest()
        noReading.surface = "Ohagey"
        XCTAssertThrowsError(try decode(kind: .registerWord(noReading)))

        var noSurface = Ohagey_Ipc_V1_RegisterWordRequest()
        noSurface.reading = "おはぎー"
        XCTAssertThrowsError(try decode(kind: .registerWord(noSurface)))
    }

    // MARK: - Ping

    func testPingMaps() throws {
        let decoded = try decode(kind: .ping(Ohagey_Ipc_V1_PingRequest()), requestID: 7)

        XCTAssertEqual(decoded.requestID, 7)
        XCTAssertEqual(decoded.body, .ping)
    }

    // MARK: - Failure modes

    /// A client on a newer schema sends a oneof case this build does not know;
    /// it arrives as no case at all. The request ID survives, so the server can
    /// still answer — that distinction is the point of `unservable`.
    func testAbsentKindIsUnservableAndKeepsRequestID() throws {
        var request = Ohagey_Ipc_V1_Request()
        request.requestID = 99

        let payload: [UInt8] = try request.serializedBytes()

        XCTAssertThrowsError(try WireCodec.decodeRequest(payload)) { error in
            guard case WireDecodeFailure.unservable(let requestID, let engineError) = error else {
                return XCTFail("expected .unservable, got \(error)")
            }
            XCTAssertEqual(requestID, 99)
            XCTAssertEqual(engineError.code, .invalidArgument)
        }
    }

    /// Bytes that never parsed carry no request ID, so the server has nothing
    /// to correlate a reply with.
    func testMalformedPayloadIsReportedSeparately() {
        // A field header claiming a length-delimited payload, then nothing.
        let payload: [UInt8] = [0x0A, 0x7F]

        XCTAssertThrowsError(try WireCodec.decodeRequest(payload)) { error in
            guard case WireDecodeFailure.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    /// An empty frame is a valid `Request` with every field defaulted, so it
    /// parses and then fails on the absent oneof rather than as malformed.
    func testEmptyPayloadIsUnservableRatherThanMalformed() {
        XCTAssertThrowsError(try WireCodec.decodeRequest([])) { error in
            guard case WireDecodeFailure.unservable(let requestID, _) = error else {
                return XCTFail("expected .unservable, got \(error)")
            }
            XCTAssertEqual(requestID, 0)
        }
    }

    // MARK: - Helper

    /// Serializes a request and puts it back through the real decode path, so
    /// the tests exercise wire bytes rather than in-memory values.
    private func decode(
        kind: Ohagey_Ipc_V1_Request.OneOf_Kind,
        requestID: UInt32 = 1
    ) throws -> Envelope<EngineRequest> {
        var request = Ohagey_Ipc_V1_Request()
        request.requestID = requestID
        request.kind = kind
        let payload: [UInt8] = try request.serializedBytes()
        return try WireCodec.decodeRequest(payload)
    }
}

final class WireResponseEncodingTests: XCTestCase {
    func testConvertResponseCarriesCandidatesAndOKStatus() throws {
        let response = try encode(.convert(
            candidates: [
                EngineCandidate(text: "変換", reading: "へんかん", score: 10),
                EngineCandidate(text: "返還", reading: "へんかん", score: 5),
            ],
            zenzaiUsed: true
        ), requestID: 3)

        XCTAssertEqual(response.requestID, 3)
        XCTAssertEqual(response.status.code, .ok)
        guard case .convert(let body) = response.kind else {
            return XCTFail("expected .convert, got \(String(describing: response.kind))")
        }
        XCTAssertTrue(body.zenzaiUsed)
        XCTAssertEqual(body.candidates.map(\.text), ["変換", "返還"])
        XCTAssertEqual(body.candidates.map(\.reading), ["へんかん", "へんかん"])
        XCTAssertEqual(body.candidates.map(\.score), [10, 5])
    }

    /// Dictionary-only fallback when the model is absent (decision 0008); the
    /// client surfaces this, so it must not silently read as "Zenzai ran".
    func testZenzaiUsedFalseSurvivesTheWire() throws {
        let response = try encode(.convert(candidates: [], zenzaiUsed: false))

        guard case .convert(let body) = response.kind else {
            return XCTFail("expected .convert, got \(String(describing: response.kind))")
        }
        XCTAssertFalse(body.zenzaiUsed)
        XCTAssertTrue(body.candidates.isEmpty)
    }

    func testCommitAndRegisterWordSendEmptyBodiesWithOKStatus() throws {
        let commit = try encode(.commit)
        XCTAssertEqual(commit.status.code, .ok)
        guard case .commit = commit.kind else {
            return XCTFail("expected .commit, got \(String(describing: commit.kind))")
        }

        let register = try encode(.registerWord)
        XCTAssertEqual(register.status.code, .ok)
        guard case .registerWord = register.kind else {
            return XCTFail("expected .registerWord, got \(String(describing: register.kind))")
        }
    }

    func testPingCarriesVersionModelStateAndBackend() throws {
        let response = try encode(.ping(engineVersion: "0.0.1", modelLoaded: true, backend: .cuda))

        guard case .ping(let body) = response.kind else {
            return XCTFail("expected .ping, got \(String(describing: response.kind))")
        }
        XCTAssertEqual(body.engineVersion, "0.0.1")
        XCTAssertTrue(body.modelLoaded)
        XCTAssertEqual(body.backend, .cuda)
    }

    func testEveryBackendHasADistinctWireValue() throws {
        var seen: Set<Int> = []
        for backend in [Backend.cpu, .cuda, .vulkan] {
            let response = try encode(.ping(engineVersion: "", modelLoaded: false, backend: backend))
            guard case .ping(let body) = response.kind else {
                return XCTFail("expected .ping")
            }
            // `unspecified` means "the sender did not say", which is never true
            // of an engine that just answered a ping.
            XCTAssertNotEqual(body.backend, .unspecified, "\(backend) mapped to unspecified")
            seen.insert(body.backend.rawValue)
        }
        XCTAssertEqual(seen.count, 3)
    }

    /// A failure sends status only. Clients must key off `status.code`, so the
    /// oneof staying unset is part of the contract, not an oversight.
    func testFailureSendsStatusWithoutABody() throws {
        let response = try encode(.failure(
            EngineError(code: .modelUnavailable, message: "weights not installed")
        ), requestID: 12)

        XCTAssertEqual(response.requestID, 12)
        XCTAssertEqual(response.status.code, .modelUnavailable)
        XCTAssertEqual(response.status.message, "weights not installed")
        XCTAssertNil(response.kind)
    }

    func testEveryErrorCodeMapsToItsOwnStatusCode() throws {
        let expected: [(EngineErrorCode, Ohagey_Ipc_V1_Status.Code)] = [
            (.invalidArgument, .invalidArgument),
            (.internalError, .internal),
            (.modelUnavailable, .modelUnavailable),
        ]
        for (engineCode, wireCode) in expected {
            let response = try encode(.failure(EngineError(code: engineCode, message: "")))
            XCTAssertEqual(response.status.code, wireCode, "\(engineCode)")
            // `ok` alongside an error would tell the client the request worked.
            XCTAssertNotEqual(response.status.code, .ok, "\(engineCode)")
        }
    }

    // MARK: - Helper

    /// Encodes through the real path and parses the bytes back, so the tests
    /// assert on what a client would actually receive.
    private func encode(
        _ body: EngineResponse,
        requestID: UInt32 = 1
    ) throws -> Ohagey_Ipc_V1_Response {
        let payload = try WireCodec.encodeResponse(Envelope(requestID: requestID, body: body))
        return try Ohagey_Ipc_V1_Response(serializedBytes: payload)
    }
}

/// The other half of an update (decisions 0007 / 0033).
///
/// Replacing Ohagey always produces a mixed pair: the engine is swapped when
/// the installer runs, while the TSF DLL waits for a restart because it is
/// loaded into every application with a text field. Until then, this engine is
/// serving the previous client — and, once the DLL catches up, a newer client
/// may reach an engine that has not been restarted yet.
///
/// The C++ side of this is covered by `tsf/Ohagey/tools/build-and-run-wire.ps1`.
/// These are the same questions asked of the generated decoder, so that a
/// future decision to hand-roll it does not quietly drop the property.
final class WireForwardCompatibilityTests: XCTestCase {
    /// Appends a field this schema does not define, as a newer client would.
    private func withUnknownField(_ payload: [UInt8], number: UInt32) -> [UInt8] {
        var bytes = payload
        // tag = field << 3 | wire type 0 (varint), then the value.
        var tag = number << 3
        while tag >= 0x80 {
            bytes.append(UInt8(tag & 0x7F) | 0x80)
            tag >>= 7
        }
        bytes.append(UInt8(tag))
        bytes.append(0x2A)
        return bytes
    }

    func testAnUnknownTopLevelFieldIsIgnored() throws {
        var convert = Ohagey_Ipc_V1_ConvertRequest()
        convert.reading = "へんかん"
        var request = Ohagey_Ipc_V1_Request()
        request.requestID = 7
        request.convert = convert

        let payload = withUnknownField(try request.serializedBytes(), number: 99)
        let decoded = try WireCodec.decodeRequest(payload)

        XCTAssertEqual(decoded.requestID, 7)
        XCTAssertEqual(decoded.body, .convert(reading: "へんかん",
                                              nBest: EngineLimits.defaultCandidateCount,
                                              precedingText: ""))
    }

    func testAnUnknownFieldInsideConvertIsIgnored() throws {
        var convert = Ohagey_Ipc_V1_ConvertRequest()
        convert.reading = "へんかん"
        convert.nBest = 12

        var request = Ohagey_Ipc_V1_Request()
        request.requestID = 8
        // The nested message carries the unknown field, so the outer decoder
        // has to hand an unrecognised tag to the inner one and survive it.
        request.convert = try Ohagey_Ipc_V1_ConvertRequest(
            serializedBytes: withUnknownField(try convert.serializedBytes(), number: 40)
        )

        let decoded = try WireCodec.decodeRequest(try request.serializedBytes())
        XCTAssertEqual(decoded.body, .convert(reading: "へんかん", nBest: 12, precedingText: ""))
    }

    func testAResponseKeepsItsShapeForAClientThatOnlyKnowsTheOldFields() throws {
        // Encoding is the side an older client reads. Nothing here asserts the
        // bytes; it asserts that a response still round-trips through the
        // schema, which is what a client walking known field numbers relies on.
        let response = Envelope<EngineResponse>(
            requestID: 3,
            body: .convert(candidates: [EngineCandidate(text: "変換", reading: "へんかん")],
                           zenzaiUsed: true)
        )
        let payload = try WireCodec.encodeResponse(response)
        let wire = try Ohagey_Ipc_V1_Response(serializedBytes: payload)

        XCTAssertEqual(wire.requestID, 3)
        XCTAssertEqual(wire.convert.candidates.count, 1)
        XCTAssertEqual(wire.convert.candidates[0].text, "変換")
    }
}
