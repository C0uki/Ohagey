// Access control for the IPC pipe (decision 0031, revising 0006).
//
// Everything the user types crosses this pipe, so the grant here is the whole
// security boundary of the engine. It is kept free of WinSDK so the properties
// that matter can be asserted in tests — the failure mode this guards against
// is someone widening the grant later for convenience and nothing noticing.

import Foundation

public enum PipeSecurity {
    /// Rights granted to a connecting client, spelled out rather than as
    /// `GENERIC_READ | GENERIC_WRITE`.
    ///
    /// The bit that matters is the one that is **not** here:
    /// `FILE_CREATE_PIPE_INSTANCE` (0x0004 — the same bit as
    /// `FILE_APPEND_DATA`), which `GENERIC_WRITE` includes. A client holding it
    /// could create another instance of our pipe name and serve other
    /// applications itself, which for an IME means reading everything the user
    /// types into them. Nothing else on this list lets a client do anything but
    /// exchange bytes on its own connection.
    ///
    /// `READ_CONTROL`, `WRITE_DAC`, `WRITE_OWNER` and `DELETE` are likewise
    /// absent: a client has no business reading or rewriting the pipe's own
    /// security descriptor.
    ///
    /// CONSEQUENCE FOR CLIENTS: opening the pipe with `GENERIC_READ |
    /// GENERIC_WRITE` will fail, because that expands to include
    /// `FILE_CREATE_PIPE_INSTANCE` and the access check demands every
    /// requested right. The TSF client must ask for these rights explicitly.
    public static let clientAccessMask: UInt32 =
        0x0000_0001         // FILE_READ_DATA
        | 0x0000_0002       // FILE_WRITE_DATA
        | 0x0000_0080       // FILE_READ_ATTRIBUTES
        | 0x0000_0100       // FILE_WRITE_ATTRIBUTES
        | 0x0010_0000       // SYNCHRONIZE

    /// `FILE_CREATE_PIPE_INSTANCE` — the right to add another instance to an
    /// existing pipe. Same bit as `FILE_APPEND_DATA`.
    public static let createPipeInstanceRight: UInt32 = 0x0000_0004

    /// Rights the engine needs **on its own pipe**.
    ///
    /// Measured, not guessed. The accept loop creates one instance per
    /// connection and Windows access-checks every create after the first
    /// against the existing pipe — the server is not exempt from its own ACL.
    /// `PIPE_ACCESS_DUPLEX` asks for `FILE_GENERIC_READ | FILE_GENERIC_WRITE`
    /// plus `FILE_CREATE_PIPE_INSTANCE`, and the check demands *every* bit, so
    /// a mask missing even `FILE_READ_EA` fails. It fails on the **second**
    /// connection, long after startup looks healthy — which is how this was
    /// found: connection one worked, then the engine died with ERROR_ACCESS_DENIED.
    ///
    /// ⚠️ **This is the limit on how narrow the grant can be, and it is worth
    /// being precise about.** The engine runs as the logged-in user, and so do
    /// the TSF clients inside each host application; a DACL cannot tell two
    /// processes of the same user apart. So this ACE — including
    /// `FILE_CREATE_PIPE_INSTANCE` — is available to every process running as
    /// that user, any of which could therefore add an instance to our pipe and
    /// serve other applications.
    ///
    /// We accept that, because a same-user process can already read our memory,
    /// inject a thread, or replace the executable outright. It is not a
    /// boundary Windows lets us draw here, and claiming otherwise would be
    /// worse than saying so plainly. The boundaries this ACL *does* hold are
    /// the ones that were actually at risk: other users on the machine,
    /// AppContainer clients, and the network.
    public static let serverAccessMask: UInt32 =
        clientAccessMask
        | createPipeInstanceRight   // FILE_CREATE_PIPE_INSTANCE
        | 0x0000_0008               // FILE_READ_EA
        | 0x0000_0010               // FILE_WRITE_EA
        | 0x0002_0000               // READ_CONTROL

    /// Security descriptor for the pipe, in SDDL.
    ///
    /// - Parameter userSID: SDDL form of the SID the engine runs as, e.g.
    ///   `S-1-5-21-…`. Looked up at runtime rather than hardcoded: the grant is
    ///   to *this* user, not to whoever happens to be logged in.
    ///
    /// Who is on the list and why:
    ///
    ///   - **the current user** — the only account that should reach an IME
    ///     holding this user's keystrokes and learning data. This replaces the
    ///     `WD` (Everyone) ACE the first draft used, which granted every
    ///     account on the machine, including other interactive users. Gets
    ///     `serverAccessMask`, because the engine itself runs here; see the
    ///     warning on that property for what it costs.
    ///   - **`SY` (LOCAL SYSTEM)** and **`BA` (Administrators)** — both can
    ///     already take ownership or debug the process, so denying them buys
    ///     nothing and would only break service-hosted and elevated clients.
    ///   - **`AC` (ALL APPLICATION PACKAGES)** — UWP / Store apps run in an
    ///     AppContainer and would otherwise be unable to connect, leaving them
    ///     with no Japanese input at all. Deliberately **not** granted
    ///     `FILE_CREATE_PIPE_INSTANCE`: a sandboxed app is the one client we
    ///     genuinely can keep from impersonating the engine, and AppContainer
    ///     is a boundary Windows does enforce.
    ///
    /// The SACL sets a **low** mandatory label with the no-write-up policy
    /// cleared. AppContainer processes run at low integrity, so without this
    /// the `AC` ACE above would be granted and then overridden by the integrity
    /// check — the same UWP apps would still be locked out.
    public static func securityDescriptorSDDL(userSID: String) -> String {
        let server = hex(serverAccessMask)
        let client = hex(clientAccessMask)
        return "D:"
            + "(A;;\(server);;;\(userSID))"
            + "(A;;\(client);;;SY)"
            + "(A;;\(client);;;BA)"
            + "(A;;\(client);;;AC)"
            + "S:(ML;;NW;;;LW)"
    }

    private static func hex(_ mask: UInt32) -> String {
        "0x" + String(mask, radix: 16, uppercase: true)
    }
}
