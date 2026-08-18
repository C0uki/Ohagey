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

    // MARK: - How often to retrain

    func testThreeCorrectionsAreEnoughOnANewProfile() {
        // The promise the feature has to keep, and the one the roadmap recorded
        // as broken: with a fixed threshold of 20, correcting the same word
        // three times did nothing at all.
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: 0), 3)
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: 100), 3)
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: 149), 3)
    }

    func testTheThresholdGrowsWithTheCorpus() {
        // Training reads the whole corpus, so a fixed threshold would spend
        // steadily more CPU per commit the longer the IME is used — measured at
        // 3ms a commit on a new profile against 133ms on a full one.
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: 500), 10)
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: 750), 15)
    }

    func testAHeavyUserIsNoWorseOffThanBefore() {
        // Capped at the value the engine used unconditionally, so no profile
        // waits longer for a retrain than it did when the threshold was fixed.
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: 1_000), 20)
        XCTAssertEqual(
            PersonalizationLayout.commitsPerTrainingRun(corpusLines: PersonalizationLayout.corpusLimit),
            20
        )
    }

    func testANonsensicalCountStillYieldsAUsableThreshold() {
        // A threshold of zero would retrain on every commit forever; a negative
        // one would never retrain at all. Neither is reachable today, but both
        // are one arithmetic slip away and only one of them is noisy.
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: -1), 3)
        XCTAssertEqual(PersonalizationLayout.commitsPerTrainingRun(corpusLines: .max), 20)
    }

    // MARK: - Reading the corpus back

    func testReadsBackWhatWasWritten() {
        XCTAssertEqual(
            PersonalizationLayout.corpusLines(from: "一行目\n二行目\n三行目\n"),
            ["一行目", "二行目", "三行目"]
        )
    }

    func testACrlfCorpusIsNotReadAsOneEnormousLine() {
        // The bug this exists for: `"\r\n"` is a single Character in Swift and
        // does not equal `"\n"`, so `split(separator: "\n")` leaves a CRLF file
        // completely unsplit. Measured on a 980 line corpus — it came back as
        // one line, and training silently learned a single 50 KB sequence.
        //
        // The engine writes LF. This happens when something else has touched
        // the file, which decision 0025 invites: opening it to see what the IME
        // remembers about you.
        XCTAssertEqual(
            PersonalizationLayout.corpusLines(from: "一行目\r\n二行目\r\n三行目\r\n"),
            ["一行目", "二行目", "三行目"]
        )
    }

    func testAMixtureOfLineEndingsStillSplits() {
        // Exactly what a file edited in Notepad and then appended to by the
        // engine looks like.
        XCTAssertEqual(
            PersonalizationLayout.corpusLines(from: "古い\r\n行\r\n新しい行\n"),
            ["古い", "行", "新しい行"]
        )
    }

    func testBlankLinesAreNotRemembered() {
        // They would be trained on as empty sequences and count against the
        // corpus limit for nothing.
        XCTAssertEqual(
            PersonalizationLayout.corpusLines(from: "一行目\n\n\r\n二行目\n"),
            ["一行目", "二行目"]
        )
        XCTAssertEqual(PersonalizationLayout.corpusLines(from: ""), [])
        XCTAssertEqual(PersonalizationLayout.corpusLines(from: "\n\n"), [])
    }

    func testAFinalLineWithoutANewlineIsStillALine() {
        // A write interrupted before its terminator, or a hand-edited file.
        XCTAssertEqual(
            PersonalizationLayout.corpusLines(from: "一行目\n二行目"),
            ["一行目", "二行目"]
        )
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
    func testBothLearningSwitchesAreOnByDefault() {
        // They were deliberately different for a month: personalisation broke
        // 15 to 18 of 30 known-correct conversions when one phrase was
        // confirmed. That was how the personal model was built — from nothing
        // rather than by resuming from a base — and Ohagey now ships a base it
        // can resume from, which leaves the same measurement at 30 of 30.
        //
        // Pinned so that flipping either one back is a decision someone makes
        // here, with the decision log open, rather than an edit nobody notices.
        XCTAssertTrue(EngineSettings.default.learningEnabled)
        XCTAssertTrue(EngineSettings.default.personalizationActive)
    }

    func testTurningLearningOffAlsoTurnsPersonalizationOff() {
        // Personalisation keeps a plain-text record of committed phrases, so it
        // cannot outlive the consent that learning stands for (decision 0025).
        var settings = EngineSettings()
        settings.learningEnabled = false
        settings.personalizationEnabled = true
        XCTAssertTrue(settings.personalizationEnabled, "the stored preference is untouched")
        XCTAssertFalse(settings.personalizationActive, "but it must not take effect")
    }

    func testPersonalizationCanBeOnWhileItIsTurnedOnDeliberately() {
        // The path someone takes when they switch it on in the settings app.
        var settings = EngineSettings()
        settings.personalizationEnabled = true
        XCTAssertTrue(settings.learningEnabled)
        XCTAssertTrue(settings.personalizationActive)
    }

    func testAlphaIsClampedToSomethingHarmless() {
        // The value comes from a user-editable file and lands in a logit
        // adjustment. Negative would invert the feature — confirming a
        // candidate would push it down the list.
        var settings = EngineSettings()
        settings.personalizationAlpha = -1
        XCTAssertEqual(settings.effectivePersonalizationAlpha, 0)

        settings.personalizationAlpha = 42
        XCTAssertEqual(
            settings.effectivePersonalizationAlpha,
            Float(EngineSettings.maximumPersonalizationAlpha)
        )

        settings.personalizationAlpha = 0.15
        XCTAssertEqual(settings.effectivePersonalizationAlpha, 0.15, accuracy: 1e-6)
    }

    func testTheDefaultAlphaMatchesAzooKeyDesktops() {
        // azooKey-Desktop ships the same converter and the same base language
        // model, and offers 0.5 / 1.0 / 1.5 with 1.0 as the default. Following
        // it beats inventing a number: an earlier default of 0.15 was reasoned
        // out rather than measured, and once Zenzai was genuinely running it
        // turned out to do nothing at all (decision 0034).
        XCTAssertEqual(EngineSettings.default.personalizationAlpha, 1.0, accuracy: 1e-9)
        XCTAssertEqual(EngineSettings.maximumPersonalizationAlpha, 1.5, accuracy: 1e-9)
    }

    func testASettingsKeyThatSaysNothingAboutItTakesTheDefault() {
        // A settings app older than this feature writes neither value, and the
        // default stands in (decision 0014's leniency rule).
        //
        // That default is now on, which is only safe because the engine
        // refuses to personalise unless the base model can be resumed from:
        // an upgrade that has not fetched the base yet inherits a switch that
        // does nothing, not one that damages conversions.
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(1),
            SettingsSchema.Key.backend: .text("cpu"),
        ])
        XCTAssertTrue(settings.personalizationActive)
        XCTAssertEqual(settings.personalizationAlpha, EngineSettings.default.personalizationAlpha)
    }

    func testAStoreThatTurnsItOffKeepsItOff() {
        // The half that matters now the default flipped: someone who switched
        // it off must not have it switched back on by an upgrade.
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(1),
            SettingsSchema.Key.personalizationEnabled: .number(0),
        ])
        XCTAssertFalse(settings.personalizationActive)
    }

    func testAStoreThatTurnsItOnGetsIt() {
        // The other half: someone who switched it on keeps it across upgrades.
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(1),
            SettingsSchema.Key.personalizationEnabled: .number(1),
        ])
        XCTAssertTrue(settings.personalizationActive)
    }

    func testAStoreThatTurnsLearningOffDoesNotGetPersonalisationAnyway() {
        let settings = EngineSettings(values: [
            SettingsSchema.Key.learningEnabled: .number(0)
        ])
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

// MARK: - Registered words

/// A registered word's lattice cost decides the order only while Zenzai is off.
/// With the model loaded, Zenzai re-ranks above the lattice — measured, the word
/// fell to 3rd behind the reading passed straight through. So the word also goes
/// into the personal n-gram, which is the one mechanism that reaches that
/// ranking (decisions 0034 / 0036).
final class RegisteredWordTrainingTests: XCTestCase {
    func testARegisteredWordIsRepeatedEnoughToBeHeard() {
        let lines = PersonalizationLayout.trainingLines(forRegisteredWords: ["Ohagey"])
        XCTAssertEqual(lines.count, PersonalizationLayout.registeredWordWeight)
        XCTAssertEqual(Set(lines), ["Ohagey"])
    }

    func testTheWeightIsWhatWasMeasuredToBeEnough() {
        // Forty is the number of confirmations that carried a candidate from
        // 20th to 1st (decision 0034). Registering a word should be at least as
        // strong as typing one forty times, since it is a statement rather than
        // a habit.
        XCTAssertEqual(PersonalizationLayout.registeredWordWeight, 40)
    }

    func testEveryRegisteredWordGetsTheSameWeight() {
        let lines = PersonalizationLayout.trainingLines(forRegisteredWords: ["Ohagey", "おはぎ"])
        XCTAssertEqual(lines.count, 2 * PersonalizationLayout.registeredWordWeight)
        XCTAssertEqual(
            lines.filter { $0 == "Ohagey" }.count,
            lines.filter { $0 == "おはぎ" }.count
        )
    }

    func testNoRegisteredWordsMeansNoLines() {
        // The caller adds these to the corpus, and an empty corpus is what tells
        // it there is nothing to train.
        XCTAssertEqual(PersonalizationLayout.trainingLines(forRegisteredWords: []), [])
    }

    func testAWordThatCouldNotBeACorpusLineIsSkipped() {
        // Same rules as a commit: the training input is line-based, so a word
        // holding a newline would become two, and something the length of a
        // paste would skew the model. The dictionary validates on the way in,
        // but the file is user-editable (decision 0013).
        let tooLong = String(repeating: "あ", count: PersonalizationLayout.maximumLineLength + 1)
        XCTAssertEqual(PersonalizationLayout.trainingLines(forRegisteredWords: [tooLong, "  "]), [])

        let flattened = PersonalizationLayout.trainingLines(forRegisteredWords: ["前半\n後半"])
        XCTAssertEqual(Set(flattened), ["前半 後半"])
    }

    // MARK: - How often a run may happen (decision 0034)

    func testTheCooldownIsProportionalToTheRunItFollows() {
        // The whole point: the interval is set by what the last run actually
        // cost, so it adjusts to the base model and to the machine without
        // anyone tuning a constant.
        XCTAssertEqual(PersonalizationLayout.cooldownSeconds(afterRunOf: 1.2), 10.8, accuracy: 0.001)
        XCTAssertEqual(PersonalizationLayout.cooldownSeconds(afterRunOf: 41.0), 369.0, accuracy: 0.001)
    }

    func testTheCooldownHonoursTheStatedDutyCycle() {
        // run / (run + cooldown) has to come out as the budget, or the
        // comment on `trainingDutyCycle` is a lie.
        for run in [0.5, 1.2, 7.9, 41.0] {
            let share = run / (run + PersonalizationLayout.cooldownSeconds(afterRunOf: run))
            XCTAssertEqual(share, PersonalizationLayout.trainingDutyCycle, accuracy: 0.0001)
        }
    }

    func testAZeroLengthRunDoesNotHoldAnythingUp() {
        // Nothing measurable was spent, so there is nothing to pay back — and
        // a clock that reports 0 must not freeze training.
        XCTAssertEqual(PersonalizationLayout.cooldownSeconds(afterRunOf: 0), 0)
        XCTAssertEqual(PersonalizationLayout.cooldownSeconds(afterRunOf: -1), 0)
    }

    // MARK: - Imported text (decision 0037)

    func testImportedTextIsKeptOutsideTheCorpus() {
        // Different file, on purpose. The corpus is a record of what was typed
        // and is trimmed oldest-first; imported text is an instruction, and a
        // word the user handed over must not fall out of the model with age.
        XCTAssertNotEqual(
            PersonalizationLayout.importedTextURL,
            PersonalizationLayout.corpusURL)
        XCTAssertEqual(PersonalizationLayout.importedTextURL.lastPathComponent, "imported.txt")
        // Beside the corpus and the generations, so erasing understands one
        // directory rather than two.
        XCTAssertEqual(
            PersonalizationLayout.importedTextURL.deletingLastPathComponent().path,
            PersonalizationLayout.directory.path)
    }

    func testImportedTextIsNormalisedLikeCommittedText() throws {
        // Reuses corpusLines/corpusLine, which is the point: a CRLF file must
        // not come back as one enormous line (Swift sees "\r\n" as a single
        // Character), and blank lines must not become training input.
        let lines = try PersonalizationLayout.importedLines(
            from: "今日はいい天気です\r\n\r\n  \r\n飛行機の時間に間に合った\r\n"
        ).get()
        XCTAssertEqual(lines, ["今日はいい天気です", "飛行機の時間に間に合った"])
    }

    func testAnImportWithNothingUsableInItIsRejected() {
        // Not "imported zero lines". A user who picks the wrong file gets told
        // rather than being shown a success over an empty import.
        XCTAssertEqual(
            PersonalizationLayout.importedLines(from: "\n  \n\r\n"),
            .failure(.empty))
    }

    func testAnOverLongImportIsRejectedRatherThanTruncated() {
        // Truncating would train on the front of a document and report the
        // whole file imported, with no way for the user to see which part took
        // effect. The number offered comes back so the message can be specific.
        let limit = 20
        let line = String(repeating: "あ", count: 11)
        XCTAssertEqual(
            PersonalizationLayout.importedLines(from: "\(line)\n\(line)\n", limit: limit),
            .failure(.tooLong(characters: 22, limit: limit)))
    }

    func testTheLimitCountsWhatTrainingWillActuallyRead() {
        // Blank lines are dropped before counting, so padding is not charged
        // for -- the limit exists to bound training cost, and training never
        // sees them.
        let line = String(repeating: "あ", count: 10)
        let padded = "\n\n\(line)\n   \n\(line)\n\n"
        XCTAssertEqual(try? PersonalizationLayout.importedLines(from: padded, limit: 20).get(),
                       [line, line])
    }

    func testTheImportLimitStaysFarBelowWhatTrainingCanHold() {
        // trainNGram keeps its counts in memory: about 780 bytes per
        // character, so four million characters needs ~3.1 GB (decision 0034).
        // The limit is what keeps an import from walking into that.
        XCTAssertLessThan(PersonalizationLayout.importedTextCharacterLimit, 4_000_000 / 10)
    }

    func testTheAddedTrainingTimeIsTheMeasuredRate() {
        // 41µs per character, measured on a release build over 90k, 419k and
        // 1.17M characters. The settings app shows this before an import, so a
        // wrong constant here becomes a wrong promise there.
        XCTAssertEqual(
            PersonalizationLayout.trainingSecondsAdded(forCharacters: 1_000_000),
            41.0,
            accuracy: 0.001)
        XCTAssertEqual(
            PersonalizationLayout.trainingSecondsAdded(
                forCharacters: PersonalizationLayout.importedTextCharacterLimit),
            4.1,
            accuracy: 0.001)
        XCTAssertEqual(PersonalizationLayout.trainingSecondsAdded(forCharacters: -5), 0)
    }
}
