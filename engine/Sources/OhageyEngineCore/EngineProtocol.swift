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
// The proto <-> model mapping lives in the OhageyEngineProto target
// (WireMapping.swift), alongside the generated types it converts from.

import Foundation

/// Bounds the wire layer applies when turning a client request into an
/// `EngineRequest`.
public enum EngineLimits {
    /// Used when a client asks for `n_best == 0`, which ohagey.proto defines as
    /// "engine default". Nine is one page of a conventional Japanese candidate
    /// window.
    public static let defaultCandidateCount = 9

    /// Upper bound on candidates one request may ask for. The count sizes work
    /// inside the converter and an array on the reply path, so a buggy or
    /// hostile client must not get to choose it freely.
    public static let maxCandidateCount = 128
}

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

extension EngineRequest {
    /// One line naming this request, safe to write to the diagnostic log.
    ///
    /// ── Lengths, never the text ────────────────────────────────────────────
    ///
    /// `engine.log` must not become a transcript of what the user wrote (see
    /// EngineLogFile), so no reading, candidate or committed string appears
    /// here — only how long each was.
    ///
    /// The lengths are the point. "変換が一回限り" is a claim about which
    /// requests arrive and what shape they are in, and the leading suspicion is
    /// that after the first conversion the TSF side can never build a reading
    /// longer than one character. A column of `reading 1` answers that from a
    /// real session; the words themselves would add nothing to it.
    public var logSummary: String {
        switch self {
        case .convert(let reading, let nBest, let precedingText):
            return "convert (reading \(reading.count), preceding \(precedingText.count), n_best \(nBest))"
        case .commit(let reading, let text, let updateLearning):
            return "commit (reading \(reading.count), text \(text.count), learn \(updateLearning))"
        case .registerWord(let reading, let surface, _):
            return "register_word (reading \(reading.count), surface \(surface.count))"
        case .ping:
            return "ping"
        }
    }
}

extension EngineResponse {
    /// How a request came out, in the same no-text terms as `logSummary`.
    public var logSummary: String {
        switch self {
        case .convert(let candidates, let zenzaiUsed):
            return "\(candidates.count) candidates (zenzai \(zenzaiUsed))"
        case .failure(let error):
            // The code and the message are ours, not the user's text.
            return "failed: \(error.code) \(error.message)"
        case .commit, .registerWord, .ping:
            return "ok"
        }
    }
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

    /// The part of a request's reading that a candidate actually converts.
    ///
    /// ── Why a candidate's reading is not the request's ─────────────────────
    ///
    /// Not every candidate consumes the whole composition. Converting
    /// `きしゃのきしゃ` offers `きしゃ` and `期しゃ` alongside the full-length
    /// ones, which is ordinary Japanese IME behaviour — the user may want to
    /// settle the first phrase and carry on. Upstream reports how much each one
    /// covers as `Candidate.correspondingCount`, in characters of the input.
    ///
    /// Reporting the request's whole reading for those is wrong in a way that
    /// matters: `ohagey.proto` says this field is what a partial commit and
    /// relearning are keyed on, so a client acting on it would consume a
    /// composition the candidate never converted, and learning would be told
    /// that `きしゃのきしゃ` reads as `期しゃ`. Measured — a harness doing
    /// exactly that taught the model to answer `記社之記社`.
    ///
    /// The engine composes with `.direct` (the TSF layer has already made kana),
    /// so one input element is one character and a prefix is exact.
    public static func reading(
        ofRequest reading: String,
        correspondingCount: Int
    ) -> String {
        // Out of range means upstream and this disagree about what is being
        // counted. The whole reading is the safe answer: it is what the field
        // meant before this existed, and it never claims a candidate covers
        // less than it does.
        guard correspondingCount > 0, correspondingCount < reading.count else { return reading }
        return String(reading.prefix(correspondingCount))
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
