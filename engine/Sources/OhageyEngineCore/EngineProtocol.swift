// Engine-side request/response model (decision 0007).
//
// These mirror the messages in ohagey.proto but are plain Swift types, not the
// generated ones. Two reasons:
//
//  1. The routing logic stays testable without protoc in the loop, and without
//     dragging SwiftProtobuf into this target.
//  2. Protobuf's generated types are wire-shaped (optionals everywhere, oneof
//     cases that can be absent). Converting once, at the edge, means the rest of
//     the engine works with values that cannot be in an impossible state.
//
// The proto <-> model mapping lives in the OhageyEngine target, next to the pipe
// server that actually speaks the wire format.

import Foundation

/// A request the engine knows how to serve.
public enum EngineRequest: Equatable, Sendable {
    /// Reading (hiragana) -> ranked candidates.
    case convert(reading: String, nBest: Int, precedingText: String)
    /// Confirm a candidate and, unless suppressed, feed it to the learning
    /// store (decisions 0024 / 0025).
    case commit(reading: String, text: String, updateLearning: Bool)
    /// Explicit user-dictionary entry (decision 0026).
    case registerWord(reading: String, surface: String, partOfSpeech: String)
    /// Liveness / capability probe (decision 0015).
    case ping
}

/// A single conversion candidate as the engine sees it.
public struct EngineCandidate: Equatable, Sendable {
    public var text: String
    public var reading: String
    public var score: Int32

    public init(text: String, reading: String, score: Int32 = 0) {
        self.text = text
        self.reading = reading
        self.score = score
    }
}

/// Why a request could not be served. Mirrors `Status.Code` in ohagey.proto.
public enum EngineErrorCode: Equatable, Sendable {
    case invalidArgument
    case internalError
    case modelUnavailable
}

public struct EngineError: Error, Equatable, Sendable {
    public var code: EngineErrorCode
    public var message: String

    public init(code: EngineErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// The engine's answer to an `EngineRequest`.
public enum EngineResponse: Equatable, Sendable {
    /// `zenzaiUsed` is false when the model is absent and the dictionary-only
    /// path served the request instead (decision 0008); the UI may surface it.
    case convert(candidates: [EngineCandidate], zenzaiUsed: Bool)
    case commit
    case registerWord
    case ping(engineVersion: String, modelLoaded: Bool, backend: Backend)
    case failure(EngineError)
}

/// Correlates a request with its response so a client can pipeline several
/// requests over one connection.
public struct Envelope<Body: Equatable & Sendable>: Equatable, Sendable {
    public var requestID: UInt32
    public var body: Body

    public init(requestID: UInt32, body: Body) {
        self.requestID = requestID
        self.body = body
    }
}
