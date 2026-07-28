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
// The access control on the pipe is decision 0031; the masks and SDDL live in
// `PipeSecurity` (OhageyEngineCore) so they can be tested.
//
// STATUS: exercised against a real client — repeated connections, conversion,
// error replies and duplicate-launch detection. Not yet exercised by
// simultaneous clients, or by an AppContainer (UWP) client.

import Foundation
#if os(Windows)
import WinSDK
#endif
import OhageyEngineCore

/// Errors surfaced while setting up or serving the pipe.
enum PipeServerError: Error {
    case sessionIdUnavailable
    case userSIDUnavailable(code: UInt32)
    case securityDescriptorFailed(code: UInt32)
    case createPipeFailed(code: UInt32)
    /// Another process holds the pipe name — a second engine, or a squatter.
    case pipeNameAlreadyOwned(name: String)
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
    /// SDDL form of the SID this process runs as.
    ///
    /// Looked up rather than hardcoded: the pipe is granted to *this* user, so
    /// a second interactive user on the same machine gets no access to it
    /// (decision 0031).
    static func currentUserSID() throws -> String {
        var rawToken: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &rawToken),
              let token = rawToken
        else {
            throw PipeServerError.userSIDUnavailable(code: GetLastError())
        }
        defer { _ = CloseHandle(token) }

        // First call sizes the buffer and is expected to fail.
        var length: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &length)
        guard length > 0 else {
            throw PipeServerError.userSIDUnavailable(code: GetLastError())
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(length),
            alignment: MemoryLayout<TOKEN_USER>.alignment
        )
        defer { buffer.deallocate() }

        guard GetTokenInformation(token, TokenUser, buffer, length, &length) else {
            throw PipeServerError.userSIDUnavailable(code: GetLastError())
        }

        let user = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee
        var rawSID: LPWSTR?
        guard ConvertSidToStringSidW(user.User.Sid, &rawSID), let sid = rawSID else {
            throw PipeServerError.userSIDUnavailable(code: GetLastError())
        }
        defer { LocalFree(sid) }
        return String(decodingCString: sid, as: UTF16.self)
    }

    /// Creates one pipe instance with the ACL from `PipeSecurity`.
    ///
    /// A pipe *instance* serves a single client, so the accept loop creates a
    /// fresh instance for each connection (`PIPE_UNLIMITED_INSTANCES`).
    ///
    /// - Parameter isFirstInstance: pass true only for the instance created
    ///   before any client has connected. It adds
    ///   `FILE_FLAG_FIRST_PIPE_INSTANCE`, which makes the call fail if the name
    ///   already exists — see `PipeServerError.pipeNameAlreadyOwned`.
    static func createPipeInstance(
        name: String,
        sddl: String,
        isFirstInstance: Bool = false
    ) throws -> HANDLE {
        var securityDescriptor: PSECURITY_DESCRIPTOR?
        let converted = sddl.withCString(encodedAs: UTF16.self) { sddl in
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

        // FILE_FLAG_FIRST_PIPE_INSTANCE makes CreateNamedPipeW fail if the name
        // is already taken, instead of quietly adding an instance to somebody
        // else's pipe. Only meaningful on the very first instance — every later
        // one legitimately joins the pipe we ourselves created.
        var openMode = DWORD(PIPE_ACCESS_DUPLEX)
        if isFirstInstance {
            openMode |= DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE)
        }

        let handle = name.withCString(encodedAs: UTF16.self) { wideName in
            CreateNamedPipeW(
                wideName,
                openMode,
                // Byte-stream mode: our own length prefix does the framing, so
                // we do not rely on message-mode boundaries.
                //
                // PIPE_REJECT_REMOTE_CLIENTS refuses connections arriving over
                // SMB. The engine only ever serves TSF clients on this machine,
                // and an IME reachable from the network is a keylogger with a
                // published address.
                DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS),
                DWORD(PIPE_UNLIMITED_INSTANCES),
                DWORD(64 * 1024),   // out buffer
                DWORD(64 * 1024),   // in buffer
                0,                  // default timeout
                &attributes
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            let code = GetLastError()
            // Someone already owns this name. Either another engine won the
            // race to start (fine — decision 0015 wants exactly one), or a
            // process is squatting the name to impersonate us. We cannot tell
            // the two apart, and in both cases the right move is to stop:
            // clients will talk to whoever holds the pipe, and adding our
            // instances to a squatter's pipe would be the worst outcome.
            if isFirstInstance && code == DWORD(ERROR_ACCESS_DENIED) {
                throw PipeServerError.pipeNameAlreadyOwned(name: name)
            }
            throw PipeServerError.createPipeFailed(code: code)
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
        let sddl = PipeSecurity.securityDescriptorSDDL(userSID: try currentUserSID())
        log("pipe SDDL: \(sddl)")
        var isFirstInstance = true

        while true {
            let handle = try createPipeInstance(
                name: name,
                sddl: sddl,
                isFirstInstance: isFirstInstance
            )
            isFirstInstance = false

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
