// Tests for settings loading and hot-reload support (decisions 0014 / 0025).
//
// The behaviour worth pinning is the difference between the two read paths.
// At startup a bad file must not stop the engine — the user would be unable to
// type. During hot-reload the same fallback would be a privacy bug: a file
// caught mid-write parses as nothing, and substituting defaults would turn
// learning back on for someone who had just switched it off.

import XCTest
@testable import OhageyEngineCore

final class EngineSettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohagey-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("settings.json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Round trip

    func testDecodesEveryField() throws {
        let url = try write("""
        {"learningEnabled":false,"backend":"cuda","zenzaiInferenceLimit":3,"idleTimeoutSeconds":60}
        """)

        let settings = try EngineSettings.decode(from: url)

        XCTAssertFalse(settings.learningEnabled)
        XCTAssertEqual(settings.backend, .cuda)
        XCTAssertEqual(settings.zenzaiInferenceLimit, 3)
        XCTAssertEqual(settings.idleTimeoutSeconds, 60)
    }

    /// The settings app may be written against an older schema, or a user may
    /// hand-edit a partial file. Missing keys must keep their defaults rather
    /// than failing the whole read — the synthesized `Codable` would throw
    /// `keyNotFound` here, and `load` would answer that by resetting
    /// *everything*, learning included.
    func testMissingFieldsKeepTheirDefaults() throws {
        let url = try write(#"{"learningEnabled":false}"#)

        let settings = try EngineSettings.decode(from: url)

        XCTAssertFalse(settings.learningEnabled)
        XCTAssertEqual(settings.backend, EngineSettings.default.backend)
        XCTAssertEqual(settings.idleTimeoutSeconds, EngineSettings.default.idleTimeoutSeconds)
    }

    /// The regression that motivates the hand-written decoder: a partial file
    /// must not hand back defaults for the one setting it does specify.
    func testPartialFileDoesNotReenableLearning() throws {
        let url = try write(#"{"learningEnabled":false}"#)
        XCTAssertFalse(EngineSettings.load(from: url).learningEnabled)
    }

    /// An unfamiliar backend means a newer settings app, not a corrupt file.
    func testUnknownBackendFallsBackWithoutDiscardingOtherSettings() throws {
        let url = try write("""
        {"learningEnabled":false,"backend":"metal","idleTimeoutSeconds":42}
        """)

        let settings = try EngineSettings.decode(from: url)

        XCTAssertEqual(settings.backend, EngineSettings.default.backend)
        XCTAssertFalse(settings.learningEnabled, "the rest of the file must survive")
        XCTAssertEqual(settings.idleTimeoutSeconds, 42)
    }

    func testEmptyObjectIsAllDefaults() throws {
        XCTAssertEqual(try EngineSettings.decode(from: try write("{}")), .default)
    }

    func testEncodedSettingsRoundTrip() throws {
        var original = EngineSettings.default
        original.learningEnabled = false
        original.backend = .vulkan
        original.zenzaiInferenceLimit = 2
        original.idleTimeoutSeconds = 15

        let url = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(original).write(to: url)

        XCTAssertEqual(try EngineSettings.decode(from: url), original)
    }

    // MARK: - The two read paths

    func testLoadFallsBackToDefaultsWhenTheFileIsMissing() {
        let missing = directory.appendingPathComponent("nope.json")
        XCTAssertEqual(EngineSettings.load(from: missing), .default)
    }

    func testLoadFallsBackToDefaultsWhenTheFileIsMalformed() throws {
        let url = try write("{ this is not json")
        XCTAssertEqual(EngineSettings.load(from: url), .default)
    }

    /// A half-written file must be distinguishable from "the user wants
    /// defaults", or hot-reload will quietly undo their choices.
    func testDecodeThrowsWhereLoadWouldSubstituteDefaults() throws {
        let malformed = try write("{ this is not json")
        XCTAssertThrowsError(try EngineSettings.decode(from: malformed))

        let missing = directory.appendingPathComponent("nope.json")
        XCTAssertThrowsError(try EngineSettings.decode(from: missing))
    }

    /// The specific regression: learning off on disk must never come back on
    /// through a failed reload.
    func testFailedReloadCannotSilentlyReenableLearning() throws {
        var current = EngineSettings.default
        current.learningEnabled = false

        let url = try write("{ truncated mid-wri")
        let reloaded = (try? EngineSettings.decode(from: url)) ?? current

        XCTAssertFalse(reloaded.learningEnabled)
    }

    // MARK: - What a running engine can apply

    func testBackendChangeRequiresRestart() {
        var updated = EngineSettings.default
        updated.backend = .vulkan

        XCTAssertEqual(
            updated.settingsRequiringRestart(comparedTo: .default),
            ["backend"]
        )
    }

    func testIdleTimeoutChangeRequiresRestart() {
        var updated = EngineSettings.default
        updated.idleTimeoutSeconds = 30

        XCTAssertEqual(
            updated.settingsRequiringRestart(comparedTo: .default),
            ["idleTimeoutSeconds"]
        )
    }

    /// These are the ones the engine reads per request, so they take effect on
    /// the next conversion without a restart.
    func testLearningAndInferenceLimitApplyLive() {
        var updated = EngineSettings.default
        updated.learningEnabled = false
        updated.zenzaiInferenceLimit = 1

        XCTAssertTrue(updated.settingsRequiringRestart(comparedTo: .default).isEmpty)
    }

    func testUnchangedSettingsRequireNothing() {
        XCTAssertTrue(EngineSettings.default.settingsRequiringRestart(comparedTo: .default).isEmpty)
    }
}
