// Dispatches decoded requests to whatever actually serves them (decision 0007).
//
// The router deliberately knows nothing about pipes, Protobuf, or the converter.
// It owns two things that are easy to get wrong and worth testing directly:
//
//  - the request ID must come back unchanged, or a pipelining client will match
//    responses to the wrong requests;
//  - a handler that throws must become a `failure` response rather than tearing
//    down the connection, because one bad request should not disconnect an
//    application that is mid-composition.

import Dispatch
import Foundation

/// Serves engine requests. Implemented in the OhageyEngine target by the type
/// that owns the converter.
///
/// `async` because the real implementation is `@MainActor`-isolated (upstream
/// pins `KanaKanjiConverter` to the main actor), while connections are handled
/// off the main actor.
public protocol EngineRequestHandling: Sendable {
    func handle(_ request: EngineRequest) async throws -> EngineResponse
}

public struct RequestRouter: Sendable {
    private let handler: any EngineRequestHandling
    private let log: (@Sendable (String) -> Void)?

    /// - Parameter log: where each served request is recorded, in the no-text
    ///   terms of `EngineRequest.logSummary`. Optional because the tests and
    ///   the harnesses have nowhere to put it; in the shipped engine it is
    ///   always supplied.
    ///
    ///   Here rather than in the pipe layer: this is the one place that sees a
    ///   decoded request *and* its response, so it can say what was asked and
    ///   what came back on one line. The first real session left no record of
    ///   either — the log said the engine started and nothing after that, which
    ///   answered none of the questions it was opened to answer.
    public init(handler: any EngineRequestHandling,
                log: (@Sendable (String) -> Void)? = nil) {
        self.handler = handler
        self.log = log
    }

    /// Routes one request and returns the response under the same request ID.
    ///
    /// Never throws: every failure is folded into `EngineResponse.failure` so
    /// the caller can always write a reply and keep the connection alive.
    public func route(_ request: Envelope<EngineRequest>) async -> Envelope<EngineResponse> {
        let started = DispatchTime.now()
        let response = await serve(request)
        if let log {
            let ms = (DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000
            log("#\(request.requestID) \(request.body.logSummary) -> \(response.body.logSummary) in \(ms)ms")
        }
        return response
    }

    private func serve(_ request: Envelope<EngineRequest>) async -> Envelope<EngineResponse> {
        do {
            let response = try await handler.handle(request.body)
            return Envelope(requestID: request.requestID, body: response)
        } catch let error as EngineError {
            return Envelope(requestID: request.requestID, body: .failure(error))
        } catch {
            // An unexpected error still has to reach the client as a well-formed
            // response; swallowing it would leave the client waiting forever.
            return Envelope(
                requestID: request.requestID,
                body: .failure(EngineError(code: .internalError,
                                           message: String(describing: error)))
            )
        }
    }
}
