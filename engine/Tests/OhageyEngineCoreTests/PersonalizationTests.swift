// Tests for the personal language model's layout rules (decision 0034).
//
// The stakes here are higher than they look. Loading a trie that is missing or
// half-written does not return an error, it terminates the process — measured,
// 0xC0000409. So "which directory counts as a usable generation" is not
// bookkeeping; getting it wrong takes the IME down mid-sentence, in every
// application at once (decision 0004).

import XCTest
@testable import OhageyEngineCore

final class PersonalizationLayoutTests: XCTestCase {
    // MARK: - Generation names

    func testRecognizesAGenerationDirectory() {
        XCTAssertEqual(PersonalizationLayout.generationNumber(fromDirectoryName: "gen-0"), 0)
        XCTAssertEqual(PersonalizationLayout.generationNumber(fromDirectoryName: "gen-7"), 7)
        XCTAssertEqual(PersonalizationLayout.generationNumber(fromDirectoryName: "gen-1024"), 1024)
    }

    func testRejectsAnythingThatIsNotAGenerationDirectory() {
        // Each of these would be loaded if it parsed, and loading the wrong
        // thing is fatal — so the parser has to be strict rather than lenient.
        for name in [
            "gen-",             // no number
            "gen-x",            // not a number
            "gen-3.partial",    // a training run in progress
            "gen--1",           // no negative generations exist
            "gen-3 ",           // trailing space
            "ngen-3",           // not our prefix
            "corpus.txt",
            "base_c_abc.marisa",
            "",
        ] {
            XCTAssertNil(
                PersonalizationLayout.generationNumber(fromDirectoryName: name),
                "\(name.debugDescription) must not be read as a generation"
            )
        }
    }

    func testAPartialDirectoryCannotBeMistakenForItsGeneration() {
        // The staging name is derived from the same generation number, so if
        // the parser were loose about suffixes a crashed run would leave
        // something that reads as complete.
        let staging = PersonalizationLayout.incompleteGenerationDirectory(4).lastPathComponent
        XCTAssertNil(PersonalizationLayout.generationNumber(fromDirectoryName: staging))
    }

    // MARK: - Choosing a generation

    func testPicksTheNewestGenerationThatIsWholeaGeneration() {
        // 5 is newer but incomplete: a run that was interrupted after creating
        // the directory. Falling back to 3 is the difference between working
        // and exiting.
        let chosen = PersonalizationLayout.newestCompleteGeneration(
            directoryNames: ["gen-3", "gen-5", "corpus.txt"]
        ) { generation, filename in
            generation == 3 || filename == PersonalizationLayout.modelFilenames[0]
        }
        XCTAssertEqual(chosen, 3)
    }

    func testPrefersTheHighestCompleteGeneration() {
        let chosen = PersonalizationLayout.newestCompleteGeneration(
            directoryNames: ["gen-1", "gen-9", "gen-2"]
        ) { _, _ in true }
        XCTAssertEqual(chosen, 9)
    }

    func testNoUsableGenerationYieldsNil() {
        XCTAssertNil(
            PersonalizationLayout.newestCompleteGeneration(directoryNames: ["gen-1", "gen-2"]) { _, _ in false }
        )
        XCTAssertNil(
            PersonalizationLayout.newestCompleteGeneration(directoryNames: []) { _, _ in true }
        )
    }

    func testCompletenessRequiresEveryFile() {
        // Only inference's four files present, `_c_bc` missing. Inference would
        // survive that; a resumed training run would not, and neither would a
        // future version that reads it. Treat the set as all-or-nothing.
        let missing = "\(PersonalizationLayout.modelPattern)_c_bc.\(PersonalizationLayout.fileExtension)"
        let chosen = PersonalizationLayout.newestCompleteGeneration(directoryNames: ["gen-1"]) { _, filename in
            filename != missing
        }
        XCTAssertNil(chosen)
    }

    func testTheFileSetIsWhatTheTrainerWrites() {
        // Pinned against upstream's trainer: it saves these five, and
        // EfficientNGram's initializer reads four of them back. A rename
        // upstream would otherwise show up as a crash rather than a test
        // failure.
        XCTAssertEqual(
            PersonalizationLayout.modelFilenames.sorted(),
            ["model_c_abc.marisa", "model_c_bc.marisa", "model_r_xbx.marisa",
             "model_u_abx.marisa", "model_u_xbc.marisa"]
        )
        XCTAssertEqual(
            PersonalizationLayout.baseFilenames.sorted(),
            ["base_c_abc.marisa", "base_c_bc.marisa", "base_r_xbx.marisa",
             "base_u_abx.marisa", "base_u_xbc.marisa"]
        )
    }

    func testTheModelPrefixIsWhatEfficientNGramExpects() {
        // `EfficientNGram(baseFilename:)` appends `_c_abc.marisa` and friends,
        // so the prefix must stop right before the underscore.
        let prefix = PersonalizationLayout.modelPrefix(generation: 2)
        XCTAssertTrue(prefix.hasSuffix(PersonalizationLayout.modelPattern), prefix)
        XCTAssertFalse(prefix.hasSuffix(".marisa"), prefix)
    }

    func testTheBaseModelSitsOutsideEveryGeneration() {
        // Generations are deleted as they are superseded. The base has to
        // survive that, or the next conversion loads a file that is gone.
        let base = PersonalizationLayout.basePrefix
        for generation in 0 ... 3 {
            XCTAssertFalse(
                base.hasPrefix(PersonalizationLayout.generationDirectory(generation).path),
                "the base model must not live inside gen-\(generation)"
            )
        }
    }

    // MARK: - The corpus

    func testKeepsOrdinaryCommittedText() {
        XCTAssertEqual(PersonalizationLayout.corpusLine(for: "今日はいい天気ですね"), "今日はいい天気ですね")
    }

    func testFlattensNewlinesRatherThanDroppingTheLine() {
        // The corpus is line-based, so an embedded newline would split one
        // commit into two entries.
        XCTAssertEqual(PersonalizationLayout.corpusLine(for: "前半\n後半"), "前半 後半")
        XCTAssertEqual(PersonalizationLayout.corpusLine(for: "前半\r\n後半"), "前半 後半")
        XCTAssertEqual(PersonalizationLayout.corpusLine(for: "前半\r後半"), "前半 後半")
    }

    func testSkipsEmptyAndWhitespaceOnlyCommits() {
        XCTAssertNil(PersonalizationLayout.corpusLine(for: ""))
        XCTAssertNil(PersonalizationLayout.corpusLine(for: "   "))
        XCTAssertNil(PersonalizationLayout.corpusLine(for: "\n\n"))
    }

    func testSkipsSomethingFarTooLongToBeAPhrase() {
        let paste = String(repeating: "あ", count: PersonalizationLayout.maximumLineLength + 1)
        XCTAssertNil(PersonalizationLayout.corpusLine(for: paste))

        let atTheLimit = String(repeating: "あ", count: PersonalizationLayout.maximumLineLength)
        XCTAssertNotNil(PersonalizationLayout.corpusLine(for: atTheLimit))
    }

    func testTrimmingKeepsTheNewestLines() {
        let lines = (1 ... 10).map(String.init)
        XCTAssertEqual(PersonalizationLayout.trimmed(corpus: lines, limit: 3), ["8", "9", "10"])
    }

    func testTrimmingLeavesAShortCorpusAlone() {
        let lines = ["a", "b"]
        XCTAssertEqual(PersonalizationLayout.trimmed(corpus: lines, limit: 10), lines)
        XCTAssertEqual(PersonalizationLayout.trimmed(corpus: lines, limit: 2), lines)
    }

    func testATrimLimitOfZeroEmptiesTheCorpus() {
        XCTAssertEqual(PersonalizationLayout.trimmed(corpus: ["a", "b"], limit: 0), [])
        XCTAssertEqual(PersonalizationLayout.trimmed(corpus: ["a"], limit: -1), [])
    }
}

// MARK: - Settings

final class PersonalizationSettingsTests: XCTestCase {
    func testPersonalizationIsOnByDefault() {
        XCTAssertTrue(EngineSettings.default.personalizationActive)
    }

    func testTurningLearningOffAlsoTurnsPersonalizationOff() {
        // Personalisation keeps a plain-text record of committed phrases, so it
        // cannot outlive the consent that learning stands for (decision 0025).
        var settings = EngineSettings()
        settings.learningEnabled = false
        XCTAssertTrue(settings.personalizationEnabled, "the stored preference is untouched")
        XCTAssertFalse(settings.personalizationActive, "but it must not take effect")
    }

    func testPersonalizationCanBeOffWhileLearningStaysOn() {
        var settings = EngineSettings()
        settings.personalizationEnabled = false
        XCTAssertTrue(settings.learningEnabled)
        XCTAssertFalse(settings.personalizationActive)
    }

    func testAlphaIsClampedToSomethingHarmless() {
        // The value comes from a user-editable file and lands in a logit
        // adjustment. Negative would invert the feature — confirming a
        // candidate would push it down the list.
        var settings = EngineSettings()
        settings.personalizationAlpha = -1
        XCTAssertEqual(settings.effectivePersonalizationAlpha, 0)

        settings.personalizationAlpha = 42
        XCTAssertEqual(settings.effectivePersonalizationAlpha, 1)

        settings.personalizationAlpha = 0.15
        XCTAssertEqual(settings.effectivePersonalizationAlpha, 0.15, accuracy: 1e-6)
    }

    func testTheDefaultAlphaIsWellBelowUpstreams() {
        // Upstream defaults to 0.5, which assumes the base language model it
        // ships. Ohagey uses a uniform base instead, against which 0.5 moved a
        // heavily-typed continuation by +4.0 logits — enough to overrule the
        // neural model outright. See decision 0034.
        XCTAssertLessThan(EngineSettings.default.personalizationAlpha, 0.5)
    }

    func testAFileThatPredatesTheseSettingsStillGetsThem() {
        // The settings app's schema is unsettled (decision 0014), so a file
        // written before this feature existed has to keep working — and has to
        // come back with personalisation on rather than silently off.
        let json = #"{"learningEnabled": true, "backend": "cpu"}"#
        let settings = try! JSONDecoder().decode(EngineSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.personalizationActive)
        XCTAssertEqual(settings.personalizationAlpha, EngineSettings.default.personalizationAlpha)
    }

    func testAFileThatTurnsLearningOffDoesNotGetPersonalisationAnyway() {
        let json = #"{"learningEnabled": false}"#
        let settings = try! JSONDecoder().decode(EngineSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.personalizationActive)
    }

    func testNeitherSettingNeedsARestart() {
        // Both are read when the request options are built, so a hot reload is
        // enough. Claiming otherwise would send the user to restart for nothing.
        var changed = EngineSettings()
        changed.personalizationEnabled = false
        changed.personalizationAlpha = 0.3
        XCTAssertEqual(changed.settingsRequiringRestart(comparedTo: .default), [])
    }
}
