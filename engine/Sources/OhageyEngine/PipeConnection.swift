// One connected client (decisions 0006 / 0007).
//
// Owns a connected pipe instance for its lifetime: read bytes, reassemble
// frames, route each request, write the framed reply. Runs on its own OS
// thread and blocks — see the concurrency note at the top of PipeServer.swift.
//
// When a bad request drops the connection and when it does not is decision
// 0030; the short version is that this connection is one host application's
// only IME, so dropping it costs the user whatever they were composing.

import Foundation
#if os(Windows)
import WinSDK
#endif
import OhageyEngineCore
import OhageyEngineProto

#if os(Windows)
final class PipeConnection {
    /// Sized to hold a typical conversion request in one read. Frames larger
    /// than this are not a problem — `FrameDecoder` reassembles across reads —
    /// so this only trades syscalls against memory.
    private static let readBufferSize = 16 * 1024

    private let handle: HANDLE
    private let router: RequestRouter
    private let log: @Sendable (String) -> Void
    private var decoder = FrameDecoder()

    init(handle: HANDLE, router: RequestRouter, log: @escaping @Sendable (String) -> Void) {
        self.handle = handle
        self.router = router
        self.log = log
    }

    /// Serves requests until the client disconnects or the stream desyncs.
    func serve() {
        defer { disconnect() }

        var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
        while true {
            var bytesRead: DWORD = 0
            let read = buffer.withUnsafeMutableBufferPointer { raw in
                ReadFile(handle, raw.baseAddress, DWORD(raw.count), &bytesRead, nil)
            }

            guard read else {
                let code = GetLastError()
                // The client closing its end is how a connection normally ends
                // — an application exiting, or TSF tearing down a context. Not
                // worth logging as a failure.
                if code != DWORD(ERROR_BROKEN_PIPE) {
                    log("read failed (\(code)); dropping connection")
                }
                return
            }
            guard bytesRead > 0 else { return }

            decoder.append(buffer.prefix(Int(bytesRead)))

            do {
                while let payload = try decoder.nextPayload() {
                    guard dispatch(payload) else { return }
                }
            } catch {
                // A length prefix we refuse to honour leaves us unable to find
                // where the next frame starts, so there is nothing to resync
                // to. Dropping the connection is the only safe move.
                log("framing error (\(error)); dropping connection")
                return
            }
        }
    }

    /// Serves one request. Returns false when the connection must be dropped.
    private func dispatch(_ payload: [UInt8]) -> Bool {
        let request: Envelope<EngineRequest>
        do {
            request = try WireCodec.decodeRequest(payload)
        } catch WireDecodeFailure.unservable(let requestID, let error) {
            // Parsed, but not something we can serve. The ID is known, so the
            // client gets a correlated failure and keeps its connection — one
            // bad request must not disconnect an app mid-composition.
            return write(Envelope(requestID: requestID, body: .failure(error)))
        } catch {
            // Nothing parsed, so there is no request ID to answer under.
            // Replying under id 0 would look like an answer to a request the
            // client never sent; dropping the connection is the honest signal.
            log("undecodable request (\(error)); dropping connection")
            return false
        }

        return write(runBlocking { [router] in await router.route(request) })
    }

    private func write(_ response: Envelope<EngineResponse>) -> Bool {
        let frame: [UInt8]
        do {
            frame = try Framing.encode(WireCodec.encodeResponse(response))
        } catch {
            // Either the response did not serialize or it exceeded the frame
            // limit. Neither is the client's fault, but we have no way to say
            // so in-band without a frame to say it in.
            log("could not encode response (\(error)); dropping connection")
            return false
        }
        return writeAll(frame)
    }

    /// `WriteFile` may write fewer bytes than asked, and a half-written frame
    /// would desync the client permanently.
    private func writeAll(_ frame: [UInt8]) -> Bool {
        var offset = 0
        while offset < frame.count {
            var written: DWORD = 0
            let ok = frame.withUnsafeBufferPointer { raw in
                WriteFile(
                    handle,
                    raw.baseAddress! + offset,
                    DWORD(frame.count - offset),
                    &written,
                    nil
                )
            }
            guard ok, written > 0 else {
                log("write failed (\(GetLastError())); dropping connection")
                return false
            }
            offset += Int(written)
        }
        return true
    }

    private func disconnect() {
        // Flush before disconnecting: DisconnectNamedPipe discards whatever the
        // client has not read yet, which would truncate the last reply.
        _ = FlushFileBuffers(handle)
        _ = DisconnectNamedPipe(handle)
        _ = CloseHandle(handle)
    }
}
#endif

/// Runs an async operation from a thread that is not driven by the concurrency
/// runtime, and blocks until it completes.
///
/// This is the seam between the blocking connection threads and the
/// `@MainActor`-isolated converter.
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    // Calling this on the main thread blocks the executor that has to run
    // `operation`, so the wait can never end. `precondition` rather than
    // `assert` because the deadlock is just as fatal in a release build, and
    // failing loudly beats the alternative: an IME that silently stops
    // responding while the user is mid-composition, with no clue why.
    precondition(
        !Thread.isMainThread,
        "runBlocking would deadlock on the main thread — call it from a connection thread"
    )

    let semaphore = DispatchSemaphore(value: 0)
    let box = MutableBox<T?>(nil)
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    // Safe to force-unwrap: the semaphore both orders the write before this
    // read and guarantees it happened.
    return box.value!
}

/// Carries a value across the isolation boundary in `runBlocking`. The
/// semaphore, not the type, is what makes the access safe.
private final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
