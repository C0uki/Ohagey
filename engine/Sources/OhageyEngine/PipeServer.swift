// Named-pipe server (decisions 0004 / 0006 / 0015).
//
// The engine is a single shared server process. TSF clients — one per host
// application (Notepad, Chrome, ...) — connect to a session-scoped pipe and
// exchange length-prefixed Protobuf frames (see Framing.swift).
//
// STATUS: skeleton. The Windows API calls below have NOT been compiled — no
// Swift toolchain is available in the environment this was written in (see
// docs/local-setup.md). Treat every WinSDK call here as needing verification
// on a real Windows build before it is trusted.

import Foundation
#if os(Windows)
import WinSDK
#endif

/// Errors surfaced while setting up or serving the pipe.
enum PipeServerError: Error {
    case sessionIdUnavailable
    case securityDescriptorFailed(code: UInt32)
    case createPipeFailed(code: UInt32)
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
    #endif

    // TODO (implementation phase):
    //  - Accept loop: create instance -> ConnectNamedPipe -> hand the handle to
    //    a per-connection task -> immediately create the next instance so a new
    //    client never finds the pipe missing.
    //  - Per-connection loop: ReadFile into a FrameDecoder, dispatch each
    //    payload through RequestRouter, WriteFile the framed response.
    //    Drop the connection on FramingError (the stream cannot be resynced).
    //  - Track the live connection count and notify IdleTimer on transitions to
    //    and from zero (decision 0015).
    //  - Decide the concurrency model: the converter is not known to be
    //    thread-safe, so conversion likely has to be serialized onto one actor
    //    even though reads happen per connection.
}
