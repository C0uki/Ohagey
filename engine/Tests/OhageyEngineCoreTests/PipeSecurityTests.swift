// Tests for the pipe's access control (decision 0031).
//
// These are regression guards, not correctness proofs: the way this grant goes
// wrong in practice is that someone widens it to make a client work — swapping
// the explicit rights back for `GA`, or re-adding Everyone — and nothing
// notices, because a wider grant breaks nothing visible. Each test below
// fails on exactly that.

import XCTest
@testable import OhageyEngineCore

final class PipeSecurityTests: XCTestCase {
    private let userSID = "S-1-5-21-1111111111-2222222222-3333333333-1001"

    private var sddl: String {
        PipeSecurity.securityDescriptorSDDL(userSID: userSID)
    }

    // MARK: - The access mask

    /// The one that would let a client stand up its own instance of our pipe
    /// name and serve other applications — i.e. keylog them.
    func testClientsCannotCreatePipeInstances() {
        XCTAssertEqual(
            PipeSecurity.clientAccessMask & PipeSecurity.createPipeInstanceRight,
            0
        )
    }

    /// The engine is not exempt from its own ACL: every instance after the
    /// first is an access-checked create against the existing pipe. Without
    /// this the second client can never be served — and the failure only shows
    /// up on the *second* connection, so it is worth pinning.
    func testServerCanCreateFurtherPipeInstances() {
        XCTAssertEqual(
            PipeSecurity.serverAccessMask & PipeSecurity.createPipeInstanceRight,
            PipeSecurity.createPipeInstanceRight
        )
    }

    /// `PIPE_ACCESS_DUPLEX` asks for FILE_GENERIC_READ | FILE_GENERIC_WRITE
    /// plus the instance right, and the access check demands every bit. This
    /// value was arrived at by watching the engine die on its *second*
    /// connection; pin it so nobody trims it back and rediscovers that.
    func testServerMaskCoversWhatPipeAccessDuplexRequests() {
        XCTAssertEqual(PipeSecurity.serverAccessMask, 0x0012_019F)
    }

    /// Even the engine's own ACE stays out of the security descriptor. (The
    /// owner holds WRITE_DAC implicitly regardless — this is about not handing
    /// it out through the DACL, not about making it impossible.)
    func testServerMaskStillExcludesOwnershipAndDeletion() {
        let forbidden: [(String, UInt32)] = [
            ("DELETE", 0x0001_0000),
            ("WRITE_DAC", 0x0004_0000),
            ("WRITE_OWNER", 0x0008_0000),
        ]
        for (name, bit) in forbidden {
            XCTAssertEqual(PipeSecurity.serverAccessMask & bit, 0, "\(name) must not be granted")
        }
    }

    /// AppContainer is the boundary Windows actually enforces for us, so a
    /// sandboxed app must not be able to impersonate the engine even though a
    /// same-user process can.
    func testAppContainerClientsDoNotGetTheInstanceRight() {
        let serverRights = "0x" + String(PipeSecurity.serverAccessMask, radix: 16, uppercase: true)
        XCTAssertFalse(sddl.contains("(A;;\(serverRights);;;AC)"))
        XCTAssertTrue(sddl.contains(";;;AC)"), "AppContainer must still be able to connect")
    }

    /// A client that can rewrite the DACL can grant itself anything else.
    func testClientsCannotTouchTheSecurityDescriptorOrDeleteThePipe() {
        let forbidden: [(String, UInt32)] = [
            ("DELETE", 0x0001_0000),
            ("READ_CONTROL", 0x0002_0000),
            ("WRITE_DAC", 0x0004_0000),
            ("WRITE_OWNER", 0x0008_0000),
        ]
        for (name, bit) in forbidden {
            XCTAssertEqual(PipeSecurity.clientAccessMask & bit, 0, "\(name) must not be granted")
        }
    }

    /// Narrow is only useful if a legitimate client can still talk.
    func testClientsCanStillReadWriteAndWait() {
        let required: [(String, UInt32)] = [
            ("FILE_READ_DATA", 0x0000_0001),
            ("FILE_WRITE_DATA", 0x0000_0002),
            ("FILE_READ_ATTRIBUTES", 0x0000_0080),
            ("FILE_WRITE_ATTRIBUTES", 0x0000_0100),
            ("SYNCHRONIZE", 0x0010_0000),
        ]
        for (name, bit) in required {
            XCTAssertEqual(PipeSecurity.clientAccessMask & bit, bit, "\(name) must be granted")
        }
    }

    /// Pins the exact value, so any change to the mask has to be deliberate
    /// enough to update a test that says why.
    func testAccessMaskIsExactlyTheDocumentedSet() {
        XCTAssertEqual(PipeSecurity.clientAccessMask, 0x0010_0183)
    }

    // MARK: - The descriptor

    /// The first draft granted `WD` (Everyone), which includes other
    /// interactive users on the same machine.
    func testEveryoneIsNotGranted() {
        XCTAssertFalse(sddl.contains(";;;WD)"), "Everyone must not appear in the DACL")
    }

    /// Generic rights are how `FILE_CREATE_PIPE_INSTANCE` sneaks back in:
    /// `GENERIC_WRITE` on a pipe includes it.
    func testNoGenericRightsAreUsed() {
        for generic in ["GA", "GR", "GW", "GX"] {
            XCTAssertFalse(sddl.contains("(A;;\(generic);;;"), "\(generic) must not be used")
        }
    }

    func testGrantsExactlyTheIntendedTrustees() {
        let client = "0x" + String(PipeSecurity.clientAccessMask, radix: 16, uppercase: true)
        let server = "0x" + String(PipeSecurity.serverAccessMask, radix: 16, uppercase: true)

        XCTAssertTrue(sddl.contains("(A;;\(server);;;\(userSID))"), "missing ACE for the current user")
        for trustee in ["SY", "BA", "AC"] {
            XCTAssertTrue(sddl.contains("(A;;\(client);;;\(trustee))"), "missing ACE for \(trustee)")
        }
        // Four allow ACEs and no more: an extra one is a widened grant.
        XCTAssertEqual(sddl.components(separatedBy: "(A;;").count - 1, 4)
    }

    /// The SID is substituted, not baked in — a hardcoded one would grant a
    /// different account than the engine runs as.
    func testUserSIDIsSubstituted() {
        let other = "S-1-5-21-9999999999-8888888888-7777777777-1002"
        let otherSDDL = PipeSecurity.securityDescriptorSDDL(userSID: other)
        XCTAssertTrue(otherSDDL.contains(other))
        XCTAssertFalse(otherSDDL.contains(userSID))
    }

    /// Without the low label, AppContainer (UWP) clients are blocked by the
    /// integrity check even though the `AC` ACE grants them access.
    func testLowIntegrityClientsCanStillWrite() {
        XCTAssertTrue(sddl.contains("S:(ML;;NW;;;LW)"))
    }
}
