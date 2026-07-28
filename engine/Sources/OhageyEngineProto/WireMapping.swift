// Wire <-> engine model mapping (decision 0007).
//
// This is the only place that knows both the generated Protobuf types and the
// engine's own request/response model. Everything upstream of it (the pipe
// server) deals in bytes; everything downstream (RequestRouter, the converter)
// deals in `EngineRequest` / `EngineResponse` values that cannot be in an
// impossible state.
//
// It lives here rather than in the `OhageyEngine` executable target — where an
// earlier comment in EngineProtocol.swift said it would — for one reason:
// SwiftPM cannot host tests against an executable target, and a mapping layer
// is exactly the kind of code that needs tests (absent oneof cases, sentinel
// values, hostile field contents). This target already depends on
// SwiftProtobuf and pulls in no C++ interop, so testing it stays cheap.

import Foundation
import OhageyEngineCore
import SwiftProtobuf

/// Why a payload could not be turned into an `EngineRequest`.
///
/// The two cases differ in what the server can do about them, which is the
/// whole reason they are distinguished: `unservable` still carries a
/// `requestID`, so the server can answer with a correlated `failure` and keep
/// the connection alive. `malformed` does not — the bytes never parsed, so
/// there is no ID to reply under.
public enum WireDecodeFailure: Error {
    case malformed(underlying: any Error)
    case unservable(requestID: UInt32, error: EngineError)
}

public enum WireCodec {
    /// Decodes one frame payload into a request the engine can serve.
    public static func decodeRequest(_ payload: [UInt8]) throws -> Envelope<EngineRequest> {
        let wire: Ohagey_Ipc_V1_Request
        do {
            wire = try Ohagey_Ipc_V1_Request(serializedBytes: payload)
        } catch {
            throw WireDecodeFailure.malformed(underlying: error)
        }

        do {
            return Envelope(requestID: wire.requestID, body: try engineRequest(from: wire))
        } catch let error as EngineError {
            throw WireDecodeFailure.unservable(requestID: wire.requestID, error: error)
        }
    }

    /// Encodes a response for the wire. The result is the frame *payload*;
    /// length-prefixing is `Framing`'s job.
    public static func encodeResponse(_ envelope: Envelope<EngineResponse>) throws -> [UInt8] {
        try wireResponse(from: envelope).serializedBytes()
    }

    // MARK: - Request

    static func engineRequest(from wire: Ohagey_Ipc_V1_Request) throws -> EngineRequest {
        // A proto3 oneof is absent when the client sent none of its cases —
        // including when it sent a message from a newer schema whose fields we
        // do not know. Both mean "nothing we can serve".
        guard let kind = wire.kind else {
            throw EngineError(code: .invalidArgument, message: "request kind is not set")
        }

        switch kind {
        case .convert(let request):
            // proto3 scalars have no "absent" state, so an empty reading is
            // indistinguishable from an omitted one. Either way there is
            // nothing to convert, and answering with an empty candidate list
            // would be read as "no conversion found" — a different thing. Fail
            // loudly so a client bug shows up as a bug.
            guard !request.reading.isEmpty else {
                throw EngineError(code: .invalidArgument, message: "convert.reading is empty")
            }
            return .convert(
                reading: request.reading,
                nBest: resolveCandidateCount(request.nBest),
                precedingText: request.context.precedingText
            )

        case .commit(let request):
            guard !request.text.isEmpty else {
                throw EngineError(code: .invalidArgument, message: "commit.text is empty")
            }
            // The reading only matters when the commit feeds learning: the
            // store is keyed by reading -> surface, and an entry with an empty
            // key would poison it. A commit that skips learning has no use for
            // the reading, so do not demand one.
            guard !request.updateLearning || !request.reading.isEmpty else {
                throw EngineError(
                    code: .invalidArgument,
                    message: "commit.reading is empty but update_learning is set"
                )
            }
            return .commit(
                reading: request.reading,
                text: request.text,
                updateLearning: request.updateLearning
            )

        case .registerWord(let request):
            guard !request.reading.isEmpty else {
                throw EngineError(code: .invalidArgument, message: "register_word.reading is empty")
            }
            guard !request.surface.isEmpty else {
                throw EngineError(code: .invalidArgument, message: "register_word.surface is empty")
            }
            // part_of_speech is documented as an optional hint, so empty is fine.
            return .registerWord(
                reading: request.reading,
                surface: request.surface,
                partOfSpeech: request.partOfSpeech
            )

        case .ping:
            return .ping
        }
    }

    /// Turns the wire's `n_best` into a usable count.
    ///
    /// Two wire-only concerns are resolved here so nothing downstream repeats
    /// them: the `0 == engine default` sentinel from the schema, and the fact
    /// that a UInt32 straight off a pipe can name a count large enough to be a
    /// denial of service if it reaches the converter.
    static func resolveCandidateCount(_ nBest: UInt32) -> Int {
        guard nBest != 0 else { return EngineLimits.defaultCandidateCount }
        return min(Int(nBest), EngineLimits.maxCandidateCount)
    }

    // MARK: - Response

    static func wireResponse(from envelope: Envelope<EngineResponse>) -> Ohagey_Ipc_V1_Response {
        var response = Ohagey_Ipc_V1_Response()
        response.requestID = envelope.requestID

        var status = Ohagey_Ipc_V1_Status()
        switch envelope.body {
        case .convert(let candidates, let zenzaiUsed):
            var body = Ohagey_Ipc_V1_ConvertResponse()
            body.candidates = candidates.map(wireCandidate)
            body.zenzaiUsed = zenzaiUsed
            response.kind = .convert(body)

        case .commit:
            response.kind = .commit(Ohagey_Ipc_V1_CommitResponse())

        case .registerWord:
            response.kind = .registerWord(Ohagey_Ipc_V1_RegisterWordResponse())

        case .ping(let engineVersion, let modelLoaded, let backend):
            var body = Ohagey_Ipc_V1_PingResponse()
            body.engineVersion = engineVersion
            body.modelLoaded = modelLoaded
            body.backend = wireBackend(backend)
            response.kind = .ping(body)

        case .failure(let error):
            status.code = wireStatusCode(error.code)
            status.message = error.message
            // `kind` is deliberately left unset. There is no body to send, and
            // a client must decide success by reading `status.code`, not by
            // checking which oneof case arrived.
        }

        response.status = status
        return response
    }

    private static func wireCandidate(_ candidate: EngineCandidate) -> Ohagey_Ipc_V1_Candidate {
        var wire = Ohagey_Ipc_V1_Candidate()
        wire.text = candidate.text
        wire.reading = candidate.reading
        wire.score = candidate.score
        // `segments` stays empty: the engine model has no bunsetsu breakdown
        // yet (see the TODO in ConversionService.convert). The field is
        // repeated, so an empty list is a valid "not provided" and clients that
        // want per-segment reconversion must already cope with it.
        return wire
    }

    private static func wireBackend(_ backend: Backend) -> Ohagey_Ipc_V1_Backend {
        switch backend {
        case .cpu: return .cpu
        case .cuda: return .cuda
        case .vulkan: return .vulkan
        }
    }

    private static func wireStatusCode(_ code: EngineErrorCode) -> Ohagey_Ipc_V1_Status.Code {
        switch code {
        case .invalidArgument: return .invalidArgument
        case .internalError: return .internal
        case .modelUnavailable: return .modelUnavailable
        }
    }
}
