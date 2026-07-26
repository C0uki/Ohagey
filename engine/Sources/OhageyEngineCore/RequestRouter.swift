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

    public init(handler: any EngineRequestHandling) {
        self.handler = handler
    }

    /// Routes one request and returns the response under the same request ID.
    ///
    /// Never throws: every failure is folded into `EngineResponse.failure` so
    /// the caller can always write a reply and keep the connection alive.
    public func route(_ request: Envelope<EngineRequest>) async -> Envelope<EngineResponse> {
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
