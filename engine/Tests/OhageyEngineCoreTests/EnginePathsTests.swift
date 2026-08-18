// Tests for model path resolution (decision 0008).
//
// The development override exists so the Zenzai path can be exercised without
// administrator rights, and it must not survive into a shipped build: the
// engine is launched on demand by whichever client connects first and inherits
// that application's environment, so in release it would let any app pick the
// model the shared engine loads for everyone.

import XCTest
@testable import OhageyEngineCore

final class EnginePathsTests: XCTestCase {
    private let programFiles = [
        "ProgramFiles": #"C:\Program Files"#
    ]

    func testDefaultsToTheShippedLocationUnderProgramFiles() {
        let url = EnginePaths.resolveModelURL(environment: programFiles, honorOverride: true)

        XCTAssertTrue(url.path.hasSuffix("Ohagey/models/ggml-model-Q5_K_M.gguf"), url.path)
        XCTAssertTrue(url.path.contains("Program Files"), url.path)
    }

    func testFallsBackWhenProgramFilesIsUnset() {
        let url = EnginePaths.resolveModelURL(environment: [:], honorOverride: true)
        XCTAssertTrue(url.path.contains("Program Files"), url.path)
    }

    // MARK: - The development override

    func testOverrideIsUsedWhenHonored() {
        var environment = programFiles
        environment[EnginePaths.modelPathOverrideVariable] = #"C:\swb\models\ggml-model-Q5_K_M.gguf"#

        let url = EnginePaths.resolveModelURL(environment: environment, honorOverride: true)

        XCTAssertEqual(url.path, "C:/swb/models/ggml-model-Q5_K_M.gguf")
    }

    /// The property that actually matters: a shipped build must ignore it
    /// completely, no matter what the launching application put in the
    /// environment.
    func testOverrideIsIgnoredWhenNotHonored() {
        var environment = programFiles
        environment[EnginePaths.modelPathOverrideVariable] = #"C:\attacker\evil.gguf"#

        let url = EnginePaths.resolveModelURL(environment: environment, honorOverride: false)

        XCTAssertFalse(url.path.contains("attacker"), url.path)
        XCTAssertTrue(url.path.contains("Program Files"), url.path)
    }

    /// An empty value is someone clearing the variable, not asking for the
    /// current directory.
    func testEmptyOverrideIsIgnored() {
        var environment = programFiles
        environment[EnginePaths.modelPathOverrideVariable] = ""

        let url = EnginePaths.resolveModelURL(environment: environment, honorOverride: true)

        XCTAssertTrue(url.path.contains("Program Files"), url.path)
    }

    /// Pins the release behaviour to the build configuration rather than to a
    /// runtime flag someone could flip.
    func testOverrideIsHonoredOnlyInDebugBuilds() {
        #if DEBUG
        XCTAssertTrue(EnginePaths.honorsModelPathOverride)
        #else
        XCTAssertFalse(EnginePaths.honorsModelPathOverride)
        #endif
    }
}
