// Tests for the request router (decision 0007).
//
// The two behaviours worth pinning down are request-ID correlation (a
// pipelining client matches responses by ID, so losing or rewriting it is a
// silent data-corruption bug) and error containment (one failed request must
// not take down a connection an application is composing text on).

import XCTest
@testable import OhageyEngineCore

/// Records what it was asked and returns whatever the test set up.
private final class StubHandler: EngineRequestHandling, @unchecked Sendable {
    enum Behaviour {
        case respond(EngineResponse)
        case fail(any Error)
    }

    private let behaviour: Behaviour
    private(set) var receivedRequests: [EngineRequest] = []

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func handle(_ request: EngineRequest) async throws -> EngineResponse {
        receivedRequests.append(request)
        switch behaviour {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        }
    }
}

private struct UnexpectedError: Error {}

final class RequestRouterTests: XCTestCase {
    func testPassesRequestToHandlerUnchanged() async {
        let handler = StubHandler(.respond(.commit))
        let router = RequestRouter(handler: handler)
        let request = EngineRequest.convert(reading: "へんかん", nBest: 5, precedingText: "きょうは")

        _ = await router.route(Envelope(requestID: 1, body: request))

        XCTAssertEqual(handler.receivedRequests, [request])
    }

    func testPreservesRequestID() async {
        let router = RequestRouter(handler: StubHandler(.respond(.commit)))

        // 0 and UInt32.max included: a client is free to use either, and an
        // implementation that treats 0 as "unset" would break pipelining.
        for id: UInt32 in [0, 1, 42, .max] {
            let response = await router.route(Envelope(requestID: id, body: .ping))
            XCTAssertEqual(response.requestID, id)
        }
    }

    func testReturnsHandlerResponse() async {
        let candidates = [
            EngineCandidate(text: "変換", reading: "へんかん", score: 10),
            EngineCandidate(text: "返還", reading: "へんかん", score: 5),
        ]
        let router = RequestRouter(
            handler: StubHandler(.respond(.convert(candidates: candidates, zenzaiUsed: true)))
        )

        let response = await router.route(
            Envelope(requestID: 7, body: .convert(reading: "へんかん", nBest: 2, precedingText: ""))
        )

        XCTAssertEqual(response.body, .convert(candidates: candidates, zenzaiUsed: true))
    }

    // MARK: - Error containment

    func testEngineErrorBecomesFailureResponse() async {
        let engineError = EngineError(code: .modelUnavailable, message: "model missing")
        let router = RequestRouter(handler: StubHandler(.fail(engineError)))

        let response = await router.route(Envelope(requestID: 3, body: .ping))

        // The code and message must survive: the settings app surfaces them.
        XCTAssertEqual(response.body, .failure(engineError))
        XCTAssertEqual(response.requestID, 3)
    }

    func testUnexpectedErrorBecomesInternalFailure() async {
        let router = RequestRouter(handler: StubHandler(.fail(UnexpectedError())))

        let response = await router.route(Envelope(requestID: 9, body: .ping))

        guard case .failure(let error) = response.body else {
            return XCTFail("expected a failure response, got \(response.body)")
        }
        // Anything unexpected still has to come back as a well-formed response;
        // swallowing it would leave the client waiting forever.
        XCTAssertEqual(error.code, .internalError)
        XCTAssertFalse(error.message.isEmpty)
        XCTAssertEqual(response.requestID, 9)
    }
}
