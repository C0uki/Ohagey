// Tests for reading settings out of the store (decisions 0014 / 0025).
//
// The store is the registry, but nothing here touches it: `SettingsSchema`
// splits the Windows API calls (RegistrySettings.swift, in the executable
// target) from the decisions about what the values mean, and those decisions
// are what a user would notice going wrong.
//
// The behaviour worth pinning: a value that is missing, of the wrong type, or
// out of range must never take the *other* settings down with it. The one that
// matters most is learning — someone who switched it off must not get it back
// because an unrelated value was malformed (decision 0025).

import XCTest
@testable import OhageyEngineCore

final class EngineSettingsTests: XCTestCase {
    // MARK: - Reading values

    func testReadsEveryField() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(0),
            SettingsSchema.Key.personalizationEnabled: .number(0),
            SettingsSchema.Key.personalizationAlphaPercent: .number(25),
            SettingsSchema.Key.backend: .text("cuda"),
            SettingsSchema.Key.zenzaiInferenceLimit: .number(3),
            SettingsSchema.Key.idleTimeoutSeconds: .number(60),
        ])

        XCTAssertFalse(settings.learningEnabled)
        XCTAssertFalse(settings.personalizationEnabled)
        XCTAssertEqual(settings.personalizationAlpha, 0.25, accuracy: 1e-9)
        XCTAssertEqual(settings.backend, .cuda)
        XCTAssertEqual(settings.zenzaiInferenceLimit, 3)
        XCTAssertEqual(settings.idleTimeoutSeconds, 60)
    }

    func testAnEmptyStoreIsAllDefaults() {
        XCTAssertEqual(EngineSettings(values: [:]), .default)
    }

    /// The settings app may be older than this build, or a user may have
    /// created a couple of values by hand. Absent values keep their defaults
    /// rather than failing the whole read.
    func testMissingValuesKeepTheirDefaults() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(0)
        ])

        XCTAssertFalse(settings.learningEnabled)
        XCTAssertEqual(settings.backend, EngineSettings.default.backend)
        XCTAssertEqual(settings.idleTimeoutSeconds, EngineSettings.default.idleTimeoutSeconds)
    }

    /// Booleans are DWORDs, and anything non-zero is true — the settings app
    /// writes 1, but a hand-edited 2 should not read as false.
    func testAnyNonZeroIsTrue() {
        for raw in [1, 2, -1] {
            let settings = EngineSettings(values: [
                SettingsSchema.Key.learningEnabled: .number(raw)
            ])
            XCTAssertTrue(settings.learningEnabled, "\(raw) should read as true")
        }
    }

    /// A value of the wrong type is not something to guess at: a REG_SZ where a
    /// DWORD belongs means the writer and this build disagree, and the default
    /// is the only answer that cannot be wrong in a new way.
    func testAValueOfTheWrongTypeFallsBackToItsDefault() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .text("false"),
            SettingsSchema.Key.backend: .number(2),
            SettingsSchema.Key.idleTimeoutSeconds: .number(42),
        ])

        XCTAssertEqual(settings.learningEnabled, EngineSettings.default.learningEnabled)
        XCTAssertEqual(settings.backend, EngineSettings.default.backend)
        XCTAssertEqual(settings.idleTimeoutSeconds, 42, "the rest must survive")
    }

    /// The regression this decoder exists for: one bad value must not reset the
    /// setting the user actually cares about.
    func testOneBadValueCannotReenableLearning() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(0),
            SettingsSchema.Key.backend: .text("metal"),
            SettingsSchema.Key.zenzaiInferenceLimit: .text("lots"),
        ])

        XCTAssertFalse(settings.learningEnabled)
    }

    /// An unfamiliar backend means a newer settings app, not a corrupt store.
    func testUnknownBackendFallsBackWithoutDiscardingOtherSettings() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(0),
            SettingsSchema.Key.backend: .text("metal"),
            SettingsSchema.Key.idleTimeoutSeconds: .number(42),
        ])

        XCTAssertEqual(settings.backend, EngineSettings.default.backend)
        XCTAssertFalse(settings.learningEnabled, "the rest of the store must survive")
        XCTAssertEqual(settings.idleTimeoutSeconds, 42)
    }

    func testBackendNameIsCaseInsensitive() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.backend: .text("CUDA")
        ])
        XCTAssertEqual(settings.backend, .cuda)
    }

    // MARK: - Ranges

    /// Out of range clamps rather than falling back. Someone who typed 9999
    /// meant "as good as it goes", and 100 delivers that; resetting to 10 would
    /// look like the setting had been ignored.
    func testInferenceLimitIsClampedToItsRange() {
        let tooBig = EngineSettings(values: [
            SettingsSchema.Key.zenzaiInferenceLimit: .number(9999)
        ])
        XCTAssertEqual(tooBig.zenzaiInferenceLimit, SettingsSchema.inferenceLimitRange.upperBound)

        // Zero would mean "Zenzai is on but does no inference", which is not a
        // state the rest of the engine is written for.
        for raw in [0, -5] {
            let tooSmall = EngineSettings(values: [
                SettingsSchema.Key.zenzaiInferenceLimit: .number(raw)
            ])
            XCTAssertEqual(tooSmall.zenzaiInferenceLimit, SettingsSchema.inferenceLimitRange.lowerBound)
        }
    }

    func testAlphaIsClampedToItsRange() {
        let tooBig = EngineSettings(values: [
            SettingsSchema.Key.personalizationAlphaPercent: .number(500)
        ])
        XCTAssertEqual(
            tooBig.personalizationAlpha,
            Double(SettingsSchema.alphaPercentRange.upperBound) / 100,
            accuracy: 1e-9,
            "the ceiling follows azooKey-Desktop's strongest setting (1.5)"
        )

        // Negative would invert personalisation: confirming a candidate would
        // push it *down* the list (decision 0034).
        let negative = EngineSettings(values: [
            SettingsSchema.Key.personalizationAlphaPercent: .number(-30)
        ])
        XCTAssertEqual(negative.personalizationAlpha, 0.0, accuracy: 1e-9)
    }

    /// Zero is meaningful here — it turns the watchdog off for someone who
    /// would rather pay the memory than the first-conversion latency
    /// (decision 0015) — so it must survive clamping.
    func testAnIdleTimeoutOfZeroIsKept() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.idleTimeoutSeconds: .number(0)
        ])
        XCTAssertEqual(settings.idleTimeoutSeconds, 0)
    }

    func testIdleTimeoutIsClampedToItsRange() {
        let tooBig = EngineSettings(values: [
            SettingsSchema.Key.idleTimeoutSeconds: .number(Int.max)
        ])
        XCTAssertEqual(tooBig.idleTimeoutSeconds, SettingsSchema.idleTimeoutRange.upperBound)
    }

    /// Percent, not a fraction, so the default has to survive the conversion —
    /// a schema that stored 15 and read back 15.0 would be a silent 15x.
    func testTheDefaultAlphaSurvivesTheStoreRoundTrip() {
        let percent = Int((EngineSettings.default.personalizationAlpha * 100).rounded())
        let settings = EngineSettings(values: [
            SettingsSchema.Key.personalizationAlphaPercent: .number(percent)
        ])
        XCTAssertEqual(
            settings.personalizationAlpha,
            EngineSettings.default.personalizationAlpha,
            accuracy: 1e-9
        )
    }

    // MARK: - Schema version

    func testAStoreWithNoVersionIsTreatedAsTheCurrentOne() {
        XCTAssertEqual(EngineSettings.schemaVersion(in: [:]), SettingsSchema.currentVersion)
    }

    /// A newer settings app is read for what this build understands rather than
    /// refused. Refusing would leave the user with an IME ignoring every
    /// setting they had chosen.
    func testAFutureSchemaVersionStillYieldsUsableSettings() {
        let values: [String: SettingsValue] = [
            SettingsSchema.Key.schemaVersion: .number(99),
            SettingsSchema.Key.learningEnabled: .number(0),
            "SomethingThisBuildHasNeverHeardOf": .number(7),
        ]

        XCTAssertEqual(EngineSettings.schemaVersion(in: values), 99)
        XCTAssertFalse(EngineSettings(values: values).learningEnabled)
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
