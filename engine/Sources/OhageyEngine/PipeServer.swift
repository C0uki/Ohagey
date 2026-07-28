// Named-pipe server (decisions 0004 / 0006 / 0015).
//
// The engine is a single shared server process. TSF clients — one per host
// application (Notepad, Chrome, ...) — connect to a session-scoped pipe and
// exchange length-prefixed Protobuf frames (see Framing.swift).
//
// CONCURRENCY: one OS thread accepts, and each accepted connection gets its own
// OS thread that blocks in `ReadFile`. Threads rather than tasks because these
// are blocking WinSDK calls, and parking a cooperative-pool thread in one of
// them can starve the pool. Nothing is lost by serializing: conversion is
// `@MainActor`-bound anyway (see ConversionService), so the per-connection
// threads exist to keep one slow client from stalling another's reads, not to
// convert in parallel. If the thread count ever becomes a problem, the fix is
// overlapped I/O with a completion port, not more tasks.
//
// STATUS: the accept and read loops now exist but have not been exercised
// against a real client. Every WinSDK call still needs verification on a live
// connection before it is trusted.

import Foundation
#if os(Windows)
import WinSDK
#endif
import OhageyEngineCore

/// Errors surfaced while setting up or serving the pipe.
enum PipeServerError: Error {
    case sessionIdUnavailable
    case securityDescriptorFailed(code: UInt32)
    case createPipeFailed(code: UInt32)
    case connectFailed(code: UInt32)
    case unsupportedPlatform
}

enum PipeServer {
    /// Pipe name is scoped by Windows session ID (decision 0006) so that
    /// concurrent interactive sessions on the same machine (fast user
    /// switching, RDP) each get their own engine and never share learning
    /// state.
    ///
    /// NOTE: the name is a *namespacing* device, not a security boundary — the
    /// ACL below is what actually restricts access.
    static func pipeName(sessionId: UInt32) -> String {
        "\\\\.\\pipe\\ohagey_session_\(sessionId)"
    }

    /// Security descriptor for the pipe, in SDDL (decision 0006).
    ///
    /// Requirements this must satisfy:
    ///   - AppContainer processes (UWP apps, sandboxed browser tabs) must be
    ///     able to connect  -> `AC` (ALL APPLICATION PACKAGES) ACE.
    ///   - Elevated (admin) processes must be able to connect. Elevation does
    ///     not remove access, so no extra ACE is needed for that direction.
    ///   - Low-integrity clients must be able to *write*, which the default
    ///     medium integrity label would block -> low mandatory label with the
    ///     no-write-up policy cleared.
    ///
    /// ⚠️ SECURITY REVIEW REQUIRED before shipping. An IME pipe carries
    /// everything the user types, so the grant below must be as narrow as it
    /// can be while still admitting sandboxed clients. Open questions:
    ///   - Should the `WD` (Everyone) ACE be narrowed to the interactive user
    ///     / logon SID instead? Every process in the session can already reach
    ///     the pipe, but Everyone is broader than necessary.
    ///   - Is `GRGW` the minimal right set, or should it be spelled as
    ///     explicit FILE_* rights?
    /// Compare against Mozc's named-pipe ACL before finalizing.
    static let securityDescriptorSDDL: String =
        "D:(A;;GRGW;;;WD)(A;;GRGW;;;AC)S:(ML;;NW;;;LW)"

    /// Windows session ID of the current process, used to derive the pipe name.
    static func currentSessionId() throws -> UInt32 {
        #if os(Windows)
        var sessionId: DWORD = 0
        guard ProcessIdToSessionId(GetCurrentProcessId(), &sessionId) else {
            throw PipeServerError.sessionIdUnavailable
        }
        return UInt32(sessionId)
        #else
        throw PipeServerError.unsupportedPlatform
        #endif
    }

    #if os(Windows)
    /// Creates one pipe instance with the ACL above.
    ///
    /// A pipe *instance* serves a single client, so the accept loop creates a
    /// fresh instance for each connection (`PIPE_UNLIMITED_INSTANCES`).
    static func createPipeInstance(name: String) throws -> HANDLE {
        var securityDescriptor: PSECURITY_DESCRIPTOR?
        let converted = securityDescriptorSDDL.withCString(encodedAs: UTF16.self) { sddl in
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl,
                DWORD(SDDL_REVISION_1),
                &securityDescriptor,
                nil
            )
        }
        guard converted, let descriptor = securityDescriptor else {
            throw PipeServerError.securityDescriptorFailed(code: GetLastError())
        }
        defer { LocalFree(descriptor) }

        var attributes = SECURITY_ATTRIBUTES(
            nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
            lpSecurityDescriptor: descriptor,
            bInheritHandle: false
        )

        let handle = name.withCString(encodedAs: UTF16.self) { wideName in
            CreateNamedPipeW(
                wideName,
                DWORD(PIPE_ACCESS_DUPLEX),
                // Byte-stream mode: our own length prefix does the framing, so
                // we do not rely on message-mode boundaries.
                DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                DWORD(PIPE_UNLIMITED_INSTANCES),
                DWORD(64 * 1024),   // out buffer
                DWORD(64 * 1024),   // in buffer
                0,                  // default timeout
                &attributes
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw PipeServerError.createPipeFailed(code: GetLastError())
        }
        return handle
    }

    /// Accepts connections until the process exits. Blocks; call it on a
    /// dedicated thread.
    ///
    /// A pipe instance serves exactly one client, so the loop creates a fresh
    /// instance per iteration. The new instance is created at the top of the
    /// next iteration, immediately after the previous connect returned, which
    /// keeps the window where no instance is listening down to the handoff
    /// itself. A client that lands inside that window gets ERROR_PIPE_BUSY and
    /// is expected to retry with `WaitNamedPipe`.
    static func runAcceptLoop(
        name: String,
        router: RequestRouter,
        watchdog: IdleWatchdog,
        log: @escaping @Sendable (String) -> Void
    ) throws {
        while true {
            let handle = try createPipeInstance(name: name)

            do {
                try waitForClient(handle)
            } catch {
                _ = CloseHandle(handle)
                // One failed connect says nothing about the next, and giving up
                // here would leave the IME with no engine at all.
                log("connect failed: \(error)")
                continue
            }

            // Counted before the thread starts: if it were counted inside, a
            // watchdog firing in between would see zero connections and exit
            // out from under a client that has already connected.
            watchdog.connectionOpened()

            // HANDLE is a raw pointer, so the compiler cannot know it is safe
            // to hand across threads. It is: ownership moves to the connection
            // thread here and the accept loop never touches this instance
            // again — closing it is the connection's job.
            let owned = SendableHandle(handle)
            let thread = Thread {
                defer { watchdog.connectionClosed() }
                PipeConnection(handle: owned.value, router: router, log: log).serve()
            }
            thread.name = "ohagey-connection"
            thread.start()
        }
    }

    /// Waits for a client on an unconnected instance.
    private static func waitForClient(_ handle: HANDLE) throws {
        if ConnectNamedPipe(handle, nil) { return }
        let code = GetLastError()
        // A client that connected in the gap between CreateNamedPipeW and this
        // call makes ConnectNamedPipe fail with ERROR_PIPE_CONNECTED. That is
        // success: the instance is connected, which is all we wanted.
        guard code == DWORD(ERROR_PIPE_CONNECTED) else {
            throw PipeServerError.connectFailed(code: code)
        }
    }

    /// Transfers a pipe handle to the thread that will own it.
    private struct SendableHandle: @unchecked Sendable {
        let value: HANDLE
        init(_ value: HANDLE) { self.value = value }
    }
    #endif
}
