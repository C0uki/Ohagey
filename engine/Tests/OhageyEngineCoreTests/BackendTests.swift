// Tests for backend selection and the status it leaves behind (decision 0028).
//
// The stakes: getting the layout wrong means loading someone else's llama.dll
// or none at all, and getting the status file wrong means the settings app
// tells the user their GPU is in use when it is not. The second is worse than
// saying nothing, because it sends them looking for the slowness elsewhere.

import XCTest
@testable import OhageyEngineCore

final class BackendLayoutTests: XCTestCase {
    private let executable = URL(fileURLWithPath: #"C:\Program Files\Ohagey\OhageyEngine.exe"#)

    // MARK: - Where the DLLs are

    func testEachBackendGetsItsOwnDirectoryBesideTheExecutable() {
        for backend in [Backend.cpu, .cuda, .vulkan] {
            let directory = BackendLayout.directory(for: backend, besideExecutableAt: executable)
            XCTAssertEqual(directory.lastPathComponent, backend.rawValue)
            XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "backends")
            XCTAssertEqual(
                directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                "Ohagey"
            )
        }
    }

    func testTheDirectoryNameIsTheSettingsValue() {
        // The settings app writes the backend as a lowercase string (decision
        // 0035) and the installer lays out one directory per name. If these
        // ever stop matching, a perfectly valid setting selects a directory
        // that does not exist and everyone silently gets CPU.
        XCTAssertEqual(BackendLayout.directoryName(for: .cuda), "cuda")
        XCTAssertEqual(BackendLayout.directoryName(for: .vulkan), "vulkan")
        XCTAssertEqual(BackendLayout.directoryName(for: .cpu), "cpu")
    }

    // MARK: - Choosing one

    /// Presence checker standing in for the filesystem.
    private func installed(_ backends: [Backend]) -> (URL) -> Bool {
        let paths = Set(backends.map {
            BackendLayout.directory(for: $0, besideExecutableAt: executable)
                .appendingPathComponent(BackendLayout.probeLibrary).path
        })
        return { paths.contains($0.path) }
    }

    func testTheRequestedBackendIsUsedWhenItIsThere() {
        let resolved = BackendLayout.resolve(
            requested: .cuda,
            besideExecutableAt: executable,
            contains: installed([.cpu, .cuda])
        )
        XCTAssertEqual(resolved?.backend, .cuda)
        XCTAssertEqual(resolved?.isRequested, true)
    }

    func testAMissingBackendFallsBackToCpu() {
        // The case that actually happens: the installer offered CUDA, the user
        // picked it, and the CUDA files were never laid down.
        let resolved = BackendLayout.resolve(
            requested: .cuda,
            besideExecutableAt: executable,
            contains: installed([.cpu])
        )
        XCTAssertEqual(resolved?.backend, .cpu)
        XCTAssertEqual(resolved?.isRequested, false)
    }

    func testNothingInstalledIsReportedRatherThanGuessed() {
        // Returning cpu here would claim a backend that is not on disk, and the
        // caller would add a nonexistent directory to the search path and think
        // it had succeeded.
        XCTAssertNil(
            BackendLayout.resolve(
                requested: .cuda,
                besideExecutableAt: executable,
                contains: installed([])
            )
        )
    }

    func testAskingForCpuWhenCpuIsMissingDoesNotFallBackToItself() {
        XCTAssertNil(
            BackendLayout.resolve(
                requested: .cpu,
                besideExecutableAt: executable,
                contains: installed([.cuda])
            ),
            "cuda is present, but nothing may be substituted for a missing cpu — the fallback is cpu itself"
        )
    }

    func testTheProbeIsTheLibraryTheEngineActuallyLinks() {
        // Probing for a directory rather than the DLL would call an empty
        // `backends\cuda\` installed.
        XCTAssertEqual(BackendLayout.probeLibrary, "llama.dll")
    }

    func testTheFallbackIsCpu() {
        XCTAssertEqual(BackendLayout.fallback, .cpu)
    }
}

// MARK: - The status file

final class BackendStatusFileTests: XCTestCase {
    private func roundTrip(_ status: BackendStatus) -> BackendStatus? {
        BackendStatusFile.parse(BackendStatusFile.serialize(status))
    }

    func testAnOrdinarySelectionSurvivesTheRoundTrip() {
        let status = BackendStatus(
            requested: .cuda,
            effective: .cuda,
            reason: .requested,
            recordedAt: Date(timeIntervalSince1970: 1_754_000_000)
        )
        let parsed = roundTrip(status)
        XCTAssertEqual(parsed, status)
        XCTAssertEqual(parsed?.isHonoringRequest, true)
    }

    func testAFallbackRecordsBothWhatWasAskedForAndWhatHappened() {
        // Recording only the effective backend would leave the settings app
        // unable to tell "you are on CPU because you chose it" from "you are on
        // CPU because CUDA would not load" — which is the whole point.
        let status = BackendStatus(
            requested: .cuda,
            effective: .cpu,
            reason: .loadFailed,
            detail: "126",
            recordedAt: Date(timeIntervalSince1970: 1_754_000_000)
        )
        let parsed = roundTrip(status)
        XCTAssertEqual(parsed?.requested, .cuda)
        XCTAssertEqual(parsed?.effective, .cpu)
        XCTAssertEqual(parsed?.reason, .loadFailed)
        XCTAssertEqual(parsed?.detail, "126")
        XCTAssertEqual(parsed?.isHonoringRequest, false)
    }

    func testNoBackendAtAllIsDistinctFromFallingBackToCpu() {
        // Absent, not empty: a blank value would have to be special-cased to
        // mean the same thing.
        let status = BackendStatus(requested: .vulkan, effective: nil, reason: .unavailable)
        let text = BackendStatusFile.serialize(status)
        XCTAssertFalse(text.contains("effective"), text)
        XCTAssertNil(roundTrip(status)?.effective)
    }

    func testUnknownKeysAreIgnoredRatherThanFatal() {
        // A newer engine writing a field this reader does not know must not
        // make the whole file unreadable — the settings app would then show
        // nothing at all, which is worse than showing less.
        let text = """
            version\t1
            requested\tcuda
            effective\tcpu
            reason\tload-failed
            future-field\tsomething
            """
        let parsed = BackendStatusFile.parse(text)
        XCTAssertEqual(parsed?.effective, .cpu)
        XCTAssertEqual(parsed?.reason, .loadFailed)
    }

    func testAFileWithoutTheFieldsThatCarryMeaningIsRejected() {
        // Half-written or truncated. Reporting a default would be reporting a
        // backend nobody selected.
        XCTAssertNil(BackendStatusFile.parse(""))
        XCTAssertNil(BackendStatusFile.parse("version\t1\n"))
        XCTAssertNil(BackendStatusFile.parse("requested\tcuda\n"), "no reason")
        XCTAssertNil(BackendStatusFile.parse("reason\trequested\n"), "no requested backend")
    }

    func testAnUnrecognisedBackendOrReasonIsRejected() {
        // Rather than quietly reading as cpu/requested, which would tell the
        // user everything is fine.
        XCTAssertNil(BackendStatusFile.parse("requested\tmetal\nreason\trequested\n"))
        XCTAssertNil(BackendStatusFile.parse("requested\tcpu\nreason\twhoops\n"))
    }

    func testAnUnreadableEffectiveBackendIsNotTreatedAsWorking() {
        // The one field where leniency would lie. Dropping to nil says "nothing
        // loaded", which is the safe reading of a value we cannot understand.
        let parsed = BackendStatusFile.parse("requested\tcuda\neffective\tmetal\nreason\trequested\n")
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.effective)
    }

    func testATimestampThatCannotBeReadDoesNotDiscardTheFile() {
        // It only decides how the age is phrased.
        let parsed = BackendStatusFile.parse("requested\tcpu\nreason\trequested\nrecorded-at\tyesterday\n")
        XCTAssertEqual(parsed?.requested, .cpu)
    }

    func testTheTimestampIsUtcIso8601() {
        // Read by C# on the other side, so it must not depend on the locale
        // either process happens to run in.
        let status = BackendStatus(
            requested: .cpu,
            effective: .cpu,
            reason: .requested,
            recordedAt: Date(timeIntervalSince1970: 1_754_000_000)
        )
        XCTAssertTrue(
            BackendStatusFile.serialize(status).contains("recorded-at\t2025-07-31T22:13:20Z"),
            BackendStatusFile.serialize(status)
        )
    }

    func testDetailCannotBreakTheLineFormat() {
        // The detail is an OS error code today, but it is the field most likely
        // to grow a message later, and a tab in it would shift every value.
        let status = BackendStatus(
            requested: .cuda,
            effective: .cpu,
            reason: .loadFailed,
            detail: "126\tcould not\r\nload"
        )
        // Six lines: version, requested, effective, reason, recorded-at,
        // detail. A tab or a newline getting through would make it more.
        let text = BackendStatusFile.serialize(status)
        XCTAssertEqual(text.split(whereSeparator: \.isNewline).count, 6, text)
        XCTAssertEqual(roundTrip(status)?.detail, "126 could not load")
    }

    func testTheReasonNamesAreTheOnesTheSettingsAppMatches() {
        // Pinned: the C# side compares against these exact strings, and a
        // rename here would show up as the settings app quietly falling through
        // to its default message.
        XCTAssertEqual(BackendSelectionReason.requested.rawValue, "requested")
        XCTAssertEqual(BackendSelectionReason.notInstalled.rawValue, "not-installed")
        XCTAssertEqual(BackendSelectionReason.loadFailed.rawValue, "load-failed")
        XCTAssertEqual(BackendSelectionReason.unavailable.rawValue, "unavailable")
    }

    func testTheFileSitsWithTheOtherPerUserData() {
        // Not Program Files: it describes what happened in this user's session,
        // and the engine runs unelevated (decision 0024).
        XCTAssertEqual(BackendStatusFile.url.lastPathComponent, "backend-status.tsv")
        XCTAssertEqual(
            BackendStatusFile.url.deletingLastPathComponent().path,
            EnginePaths.userDataDirectory.path
        )
    }
}
