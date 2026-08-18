// Trains and publishes the personal n-gram model (decision 0034).
//
// The layout and the pure decisions are in OhageyEngineCore/Personalization.swift;
// this is the part that touches the corpus file, calls `trainNGram`, and hands
// the converter a `PersonalizationMode`.
//
// API NOTE: `trainNGram` comes from AzooKeyKanaKanjiConverter's EfficientNGram
// target, which upstream does not export and does not build on Windows at all.
// Both are fixed in the fork this package pins — see decision 0034 and the
// dependency comment in Package.swift.

import Foundation
import EfficientNGram
import KanaKanjiConverterModuleWithDefaultDictionary
import OhageyEngineCore

/// Owns the personal language model: the corpus behind it, the training runs
/// that rebuild it, and which generation the converter is currently told about.
///
/// `@MainActor` to match `ConversionService`, which is the only caller. The
/// training itself deliberately runs off the main actor — it takes on the order
/// of a second at the corpus limit, and the main actor is where conversion
/// happens, so doing it here would stall typing.
@MainActor
final class PersonalLanguageModel {
    /// Commits since the last training run was started.
    private var unlearnedCommits = 0

    /// Generation currently offered to the converter, or nil when there is
    /// nothing usable yet — a fresh profile, or personalisation switched off.
    private var publishedGeneration: Int?

    /// Set while a training run is in flight, so commits during it do not pile
    /// up a second one.
    private var isTraining = false

    /// Whether the base model is present. Without it there is nothing to offer:
    /// the converter loads base and personal together, and a missing file takes
    /// the process down rather than failing.
    private var baseIsReady = false

    /// True when the installed base model is in use rather than the generated
    /// empty stand-in.
    private var usesRealBaseModel = false

    /// Surfaces of the words the user registered, as of the last update.
    ///
    /// Held here rather than read from the dictionary at training time so that
    /// this type keeps its one job — the corpus, the training runs, and which
    /// generation is published — and does not also have to know the dictionary's
    /// file format.
    private var registeredWords: [String] = []

    /// Text the user imported from the settings app (decision 0037).
    ///
    /// Cached rather than read at training time for the same reason as
    /// `corpusLines`: the file can be 100,000 characters and a training run is
    /// not the only thing that asks.
    private var importedLines: [String] = []

    /// Modification date of `imported.txt` as of the last read.
    ///
    /// The settings app writes this file directly and the engine has to notice
    /// (decision 0013). Checked by `stat` before a conversion rather than
    /// watched on a thread — exactly what `UserDictionaryStore` does with
    /// `userdict.tsv`, for exactly the same relationship. One `stat` is nothing
    /// beside a conversion, it cannot miss a notification, and it needs no
    /// second mechanism alongside the settings watcher.
    private var importedModificationDate: Date?

    /// Corpus lines as of the last time they were counted.
    ///
    /// Kept rather than read back on every commit: the threshold depends on it,
    /// and re-reading a 10,000 line file to decide whether to retrain would cost
    /// more than the decision is worth. Seeded at startup and kept in step by
    /// the append; the training run corrects it from the real count.
    private var corpusLines = 0

    private let fileManager = FileManager.default

    /// Injected rather than reached for globally, matching `SettingsWatcher`:
    /// the engine's logging is a closure owned by main.swift, so that nothing
    /// in the module has to know where log lines end up.
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    // MARK: - Startup

    /// Prepares the directory, discards debris from an interrupted run, and
    /// finds the newest usable generation.
    ///
    /// Never throws: personalisation failing to start must not stop the engine.
    /// The user would rather have conversion without it than no IME at all.
    func prepare() {
        do {
            try fileManager.createDirectory(
                at: PersonalizationLayout.directory,
                withIntermediateDirectories: true
            )
            discardPartialGenerations()
            baseIsReady = try ensureBaseModel()
            // Counted once here rather than on each commit; see `corpusLines`.
            corpusLines = readCorpus().count
            reloadImportedTextIfChanged()
            publishedGeneration = newestCompleteGeneration()
            if let publishedGeneration {
                log("personalisation: generation \(publishedGeneration) loaded")
            } else {
                log("personalisation: no trained model yet")
            }
        } catch {
            log("personalisation unavailable: \(error)")
            baseIsReady = false
            publishedGeneration = nil
        }
    }

    /// Makes sure some base model is usable, and reports whether it is.
    ///
    /// The real one ships beside the Zenzai weights and is fetched at install
    /// time (decision 0008's route, because its licence is unstated at source).
    /// When it is there, nothing is generated — that model is what makes the
    /// mixing mean anything.
    ///
    /// When it is missing, an empty base is generated so personalisation still
    /// runs rather than being switched off entirely. **Measured, that fallback
    /// is inert**: `ZenzContext` adds `alpha * (log p_personal - log p_base)`,
    /// and a base that scores every token identically leaves the personal model
    /// pushing against nothing. Forty confirmations of one phrase moved its rank
    /// not at all and broke none of the 30 other eval items — against 2位→1位
    /// and 18 broken with the real base (decision 0034).
    ///
    /// So this is not "weaker personalisation", it is none, and it is kept only
    /// because switching the feature off mid-session would be a larger surprise
    /// than leaving it running. It is a fallback, not a design, and the log says
    /// so.
    private func ensureBaseModel() throws -> Bool {
        if EnginePaths.isBaseLanguageModelAvailable {
            usesRealBaseModel = true
            if EnginePaths.isBaseLanguageModelResumable {
                log("personalisation: using the installed base language model")
            } else {
                // Loud, because everything else looks fine: the model is
                // there, it loads, and the switch in the settings app is
                // available. It just cannot be continued from, and the only
                // personal model we could build without that is the one
                // measured to break 8-18 of 30 conversions.
                log("personalisation: the installed base language model cannot be resumed from (no _c_bc) — personalisation will do nothing rather than train a model that damages unrelated conversions (decision 0034)")
            }
            return true
        }
        usesRealBaseModel = false

        if baseModelExists() { return true }
        log("personalisation: no base language model installed — falling back to an empty one, which is INERT: it will neither improve nor damage the ranking (decision 0034)")

        log("personalisation: building the empty base model")
        let staging = PersonalizationLayout.directory
            .appendingPathComponent("base.partial", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        trainNGram(
            lines: [],
            n: Self.ngramOrder,
            baseFilePattern: PersonalizationLayout.basePattern,
            outputDir: staging.path
        )

        // Straight into the shared directory rather than by moving the
        // directory, because the base files sit beside the generations rather
        // than in one of their own. Safe despite that: nothing reads the base
        // until `baseIsReady`, which is only set once every file has arrived.
        for filename in PersonalizationLayout.baseFilenames {
            let source = staging.appendingPathComponent(filename)
            let destination = PersonalizationLayout.directory.appendingPathComponent(filename)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
        try? fileManager.removeItem(at: staging)

        return baseModelExists()
    }

    private func baseModelExists() -> Bool {
        PersonalizationLayout.baseFilenames.allSatisfy {
            fileManager.fileExists(
                atPath: PersonalizationLayout.directory.appendingPathComponent($0).path
            )
        }
    }

    private func newestCompleteGeneration() -> Int? {
        let names = (try? fileManager.contentsOfDirectory(
            atPath: PersonalizationLayout.directory.path
        )) ?? []
        return PersonalizationLayout.newestCompleteGeneration(directoryNames: names) { generation, filename in
            fileManager.fileExists(
                atPath: PersonalizationLayout.generationDirectory(generation)
                    .appendingPathComponent(filename).path
            )
        }
    }

    /// Removes directories left behind by a training run that did not finish.
    ///
    /// They are named so they can never be mistaken for a generation, so this
    /// is housekeeping rather than safety — but an engine killed repeatedly
    /// mid-training would otherwise accumulate them.
    private func discardPartialGenerations() {
        let names = (try? fileManager.contentsOfDirectory(
            atPath: PersonalizationLayout.directory.path
        )) ?? []
        for name in names where name.hasSuffix(PersonalizationLayout.incompleteSuffix) {
            try? fileManager.removeItem(
                at: PersonalizationLayout.directory.appendingPathComponent(name)
            )
        }
    }

    // MARK: - What the converter is told

    /// The personalisation to apply, or nil to leave Zenzai's ranking alone.
    ///
    /// nil whenever anything is missing rather than substituting a default:
    /// every path into the converter here ends in loading a trie, and loading
    /// one that is not there is fatal.
    func personalizationMode(
        settings: EngineSettings
    ) -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        // ── Registered words no longer keep this on ────────────────────────
        //
        // They used to: decision 0036 routed them through here because it is
        // the only mechanism that reaches Zenzai's ranking, and without it a
        // registered word lands 3rd instead of 1st.
        //
        // Measured what that cost. Registering one word — `おはぎー` — put it at
        // the top as intended and broke **18 of 30** otherwise-correct
        // conversions: `病院の予約` came back as `病医ンノ予ヤ久`. That is the
        // same damage, and the same number, as personalisation itself, because
        // it is the same mechanism handed a model trained on almost nothing.
        //
        // So a registered word gets its lattice cost and nothing more until the
        // calibration problem behind all of this is understood (decision 0034,
        // addendum 10). 3rd with the rest of the language intact beats 1st with
        // half of it broken.
        // ── And nothing happens unless the base can be resumed from ────────
        //
        // This is the guard that keeps the switch from being a trap.
        //
        // A personal model trained from nothing assigns the smoothing floor
        // to every token the user has not typed, and subtracting the base
        // then penalises the whole rest of the language: 8 to 18 of 30
        // otherwise-correct conversions lost, measured. Trained by resuming
        // from the base it is the same model plus the user's counts, the
        // difference outside their own text is 0.00 logits, and the same
        // measurement breaks nothing while still promoting the target.
        //
        // The difference is one file. `Miwa-Keita/base_n5_lm` publishes four
        // and `SwiftTrainer(baseFilePattern:)` needs five, so on a machine
        // with the shipped base the only personal model we can build is the
        // harmful one. Rather than let the setting produce that, it produces
        // nothing — the user gets no personalisation instead of a worse IME,
        // and the settings app says which it is.
        //
        // `usesRealBaseModel` matters as much as the file count: the empty
        // base generated when none is installed has all five files and
        // resuming from it is training from nothing by another name.
        guard settings.personalizationActive,
              baseIsReady,
              usesRealBaseModel,
              EnginePaths.isBaseLanguageModelResumable,
              let generation = publishedGeneration
        else { return nil }

        return .init(
            // Always the installed one: the guard above has already refused
            // every other case.
            baseNgramLanguageModel: EnginePaths.baseLanguageModelPrefix,
            personalNgramLanguageModel: PersonalizationLayout.modelPrefix(generation: generation),
            n: Self.ngramOrder,
            d: Self.discount,
            alpha: settings.effectivePersonalizationAlpha
        )
    }

    /// Order of the n-gram, and the Kneser-Ney discount.
    ///
    /// Upstream's defaults, and upstream's tokenizer and trainer are built for
    /// them; they are named here only so the training run and the inference
    /// side cannot drift apart. A model trained at one order and read at
    /// another silently returns nonsense.
    ///
    /// `nonisolated` because the training run reads them from off the main
    /// actor. Without it these inherit the type's isolation, which is a warning
    /// today and an error in the Swift 6 language mode.
    /// When the next training run may start.
    ///
    /// Set from the duration of the last one (see
    /// `PersonalizationLayout.cooldownSeconds`). Distant past by default so
    /// the first run is never delayed.
    private var nextRunNotBefore = Date.distantPast

    /// Whether a deferred run is already queued, so a burst of commits
    /// queues one and not forty.
    private var deferredRunQueued = false

    private nonisolated static let ngramOrder = 5
    private nonisolated static let discount = 0.75

    // MARK: - Recording and training

    /// Records a confirmed phrase and retrains once enough have accumulated.
    func record(text: String, settings: EngineSettings) {
        guard settings.personalizationActive, baseIsReady else { return }
        guard let line = PersonalizationLayout.corpusLine(for: text) else { return }

        appendToCorpus(line)
        unlearnedCommits += 1
        corpusLines += 1

        // Scaled to the corpus, not fixed: training reads all of it every run,
        // so a constant threshold would spend steadily more CPU per commit the
        // longer someone uses the IME. See `commitsPerTrainingRun`.
        let threshold = PersonalizationLayout.commitsPerTrainingRun(corpusLines: corpusLines)
        guard unlearnedCommits >= threshold, !isTraining else { return }
        startTraining(settings: settings)
    }

    private func appendToCorpus(_ line: String) {
        let url = PersonalizationLayout.corpusURL
        guard let data = (line + "\n").data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Reads the corpus back, dropping anything beyond the limit.
    ///
    /// The trim is applied on read *and* written back, so the file cannot grow
    /// without bound across sessions.
    private func readCorpus() -> [String] {
        guard let contents = try? String(contentsOf: PersonalizationLayout.corpusURL, encoding: .utf8)
        else { return [] }

        let lines = PersonalizationLayout.corpusLines(from: contents)
        let trimmed = PersonalizationLayout.trimmed(corpus: lines)
        if trimmed.count < lines.count {
            try? trimmed.joined(separator: "\n")
                .appending("\n")
                .write(to: PersonalizationLayout.corpusURL, atomically: true, encoding: .utf8)
        }
        return trimmed
    }

    // MARK: - Imported text

    /// Rereads `imported.txt` if it has changed, and retrains when it has.
    ///
    /// Called before conversions rather than on a watcher, matching
    /// `UserDictionaryStore.reloadIfChanged`. Returns whether the contents
    /// moved, so the caller can see it happen in a log.
    @discardableResult
    func reloadImportedTextIfChanged() -> Bool {
        let url = PersonalizationLayout.importedTextURL
        let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date

        // An absent file with no lines is the ordinary case. An absent file
        // *after* having had lines means the user deleted the import, and that
        // has to reach the model — otherwise "delete" leaves the text training
        // the IME until the next engine restart.
        guard modified != importedModificationDate else { return false }
        importedModificationDate = modified

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            let had = !importedLines.isEmpty
            importedLines = []
            if had { log("personalisation: imported text removed") }
            return had
        }

        switch PersonalizationLayout.importedLines(from: contents) {
        case .success(let lines):
            importedLines = lines
            log("personalisation: imported text loaded (\(lines.count) lines,"
                + " \(lines.reduce(0) { $0 + $1.count }) characters)")
            return true
        case .failure(let rejection):
            // The settings app validates before writing, so reaching here means
            // the file was edited by hand or written by something else. Dropped
            // rather than trimmed, and said out loud: training on the front of
            // a file someone thought was fully imported is worse than not
            // training on it.
            let had = !importedLines.isEmpty
            importedLines = []
            log("personalisation: imported text ignored (\(rejection))")
            return had
        }
    }

    /// Rereads the imported text and retrains if it changed.
    ///
    /// The counterpart of `updateRegisteredWords` for a file the settings app
    /// owns. Separate from `reloadImportedTextIfChanged` so that startup can
    /// load it without also starting a training run before the base is ready.
    func refreshImportedText(settings: EngineSettings) {
        guard reloadImportedTextIfChanged() else { return }
        guard settings.personalizationActive, baseIsReady, !isTraining else { return }
        startTraining(settings: settings)
    }

    /// Trains once at startup when there is material but no model built from it.
    ///
    /// ── The gap this closes ────────────────────────────────────────────────
    ///
    /// The engine runs on demand and exits when idle (decision 0015), so the
    /// ordinary way to import text is with no engine running at all: the
    /// settings app writes the file, and the next keystroke starts an engine
    /// that has never seen it.
    ///
    /// That engine reads `imported.txt` in `prepare` and records its
    /// modification date, so `refreshImportedText` then correctly reports
    /// nothing changed — and without this, the import would sit on disk
    /// training nothing until the user happened to confirm a phrase.
    ///
    /// Deliberately conditional on there being no published generation rather
    /// than running on every start: resuming from the base costs about a
    /// second and 48 MB per megabyte of base, and an engine that retrained
    /// every time it woke up would spend that on every first keystroke of the
    /// day.
    func trainIfNothingPublished(settings: EngineSettings) {
        guard publishedGeneration == nil else { return }
        guard settings.personalizationActive, baseIsReady, !isTraining else { return }
        // Only for material the user handed over deliberately. The corpus is
        // handled by `record`, which counts commits and decides for itself.
        guard !importedLines.isEmpty || !registeredWords.isEmpty else { return }
        log("personalisation: material is present but no model is built from it — training")
        startTraining(settings: settings)
    }

    /// Takes the current registered words and retrains if they changed.
    ///
    /// Called whenever the dictionary is loaded or edited. Retraining on every
    /// call would rebuild the model on each conversion, since the dictionary is
    /// stat-ed that often (see `ConversionService.convert`).
    func updateRegisteredWords(_ words: [String], settings: EngineSettings) {
        guard words != registeredWords else { return }
        registeredWords = words
        // Only while personalisation is on. They are still weighted heavily in
        // the training input when it is (an explicit word should outrank a
        // habit inside a feature the user opted into) — but they no longer
        // switch the feature on by themselves. See `personalizationMode`.
        guard settings.personalizationActive, baseIsReady, !isTraining else { return }
        startTraining(settings: settings)
    }

    /// Starts a run, or queues one for when the cooldown is up.
    ///
    /// The cooldown delays rather than cancels: the commits that asked for
    /// this run stay counted, and it happens later. Cancelling would mean a
    /// user who corrects a word ten times in a row gets one of those
    /// corrections learned and nine dropped.
    private func startTraining(settings: EngineSettings) {
        let wait = nextRunNotBefore.timeIntervalSinceNow
        if wait > 0 {
            guard !deferredRunQueued else { return }
            deferredRunQueued = true
            log("personalisation: deferring the next training run by \(Int(wait.rounded()))s"
                + " to stay under \(Int(PersonalizationLayout.trainingDutyCycle * 100))% of the machine")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self else { return }
                self.deferredRunQueued = false
                // Re-checked rather than assumed: personalisation may have
                // been switched off while this was waiting (decision 0025).
                guard settings.personalizationActive, self.baseIsReady, !self.isTraining else { return }
                self.beginTraining(settings: settings)
            }
            return
        }
        beginTraining(settings: settings)
    }

    private func beginTraining(settings: EngineSettings) {
        // The corpus only when it is allowed to exist. Registered words are
        // always included: they are an explicit instruction rather than a
        // record of what someone typed, so switching learning off must not
        // switch them off too (decisions 0025 / 0036).
        let corpus = settings.personalizationActive ? readCorpus() : []
        // The authoritative count, which also picks up any trimming the read
        // just did — the running tally cannot know about that.
        corpusLines = corpus.count

        // Imported text sits with the registered words rather than with the
        // corpus: both are things the user handed over on purpose, so neither
        // is switched off by switching learning off (decisions 0025 / 0037).
        // Unweighted, unlike registered words — this is prose, and repeating it
        // forty times would make the model believe the document rather than
        // learn the vocabulary in it.
        let lines = PersonalizationLayout.trainingLines(forRegisteredWords: registeredWords)
            + importedLines
            + corpus
        guard !lines.isEmpty else {
            unlearnedCommits = 0
            return
        }

        let generation = (publishedGeneration ?? 0) + 1
        isTraining = true
        unlearnedCommits = 0

        // ── Continue from the base model when there is one to continue from ──
        //
        // Read here, on the main actor, rather than inside the detached task:
        // it is a filesystem check against state the task must not race with.
        //
        // Nil is the ordinary case today and the reason personalisation costs
        // what it does. See `EnginePaths.isBaseLanguageModelResumable`.
        let resumeFrom = EnginePaths.isBaseLanguageModelResumable
            ? EnginePaths.baseLanguageModelPrefix
            : nil

        // Detached, at utility priority: this is a second of CPU that must not
        // come out of the time budget for the keystroke that triggered it.
        Task.detached(priority: .utility) { [fileManager] in
            let started = DispatchTime.now().uptimeNanoseconds
            let trained = Self.train(
                generation: generation,
                lines: lines,
                resumeFrom: resumeFrom,
                fileManager: fileManager
            )
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            await MainActor.run {
                self.finishTraining(
                    generation: generation,
                    succeeded: trained,
                    lines: lines.count,
                    milliseconds: elapsed,
                    settings: settings
                )
            }
        }
    }

    /// Trains into a staging directory and moves it into place as a unit.
    ///
    /// `nonisolated static` so it runs off the main actor without capturing
    /// any of this object's state. Everything it needs is passed in, and the
    /// only shared thing it touches is the filesystem — at paths derived from
    /// a generation number that the main actor allocated and will not reuse.
    private nonisolated static func train(
        generation: Int,
        lines: [String],
        resumeFrom: String?,
        fileManager: FileManager
    ) -> Bool {
        let staging = PersonalizationLayout.incompleteGenerationDirectory(generation)
        let destination = PersonalizationLayout.generationDirectory(generation)

        do {
            try? fileManager.removeItem(at: staging)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            // `resumeFilePattern` is what decides whether this is a model of
            // the user's text or a copy of the language with the user's text
            // added to it. The second is the one that can be subtracted from
            // the base without punishing every word they have not typed.
            trainNGram(
                lines: lines,
                n: ngramOrder,
                baseFilePattern: PersonalizationLayout.modelPattern,
                outputDir: staging.path,
                resumeFilePattern: resumeFrom
            )

            // Refuse to publish an incomplete set rather than discovering it
            // later, when discovering it means the process exiting.
            let complete = PersonalizationLayout.modelFilenames.allSatisfy {
                fileManager.fileExists(atPath: staging.appendingPathComponent($0).path)
            }
            guard complete else {
                try? fileManager.removeItem(at: staging)
                return false
            }

            // The move is what makes the swap safe: a reader sees the old
            // directory or the new one, never a directory being filled in.
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            return true
        } catch {
            try? fileManager.removeItem(at: staging)
            return false
        }
    }

    private func finishTraining(
        generation: Int,
        succeeded: Bool,
        lines: Int,
        milliseconds: Double,
        // Carried through the round trip rather than re-read: the settings
        // this run was started under are the ones that decide whether a
        // follow-up run is allowed. A hot reload mid-training must not turn
        // a finished run into one that starts another after the user has
        // just switched personalisation off (decision 0025).
        settings: EngineSettings
    ) {
        isTraining = false
        // Recorded whether or not it succeeded: a run that failed still spent
        // the time and the memory.
        nextRunNotBefore = Date().addingTimeInterval(
            PersonalizationLayout.cooldownSeconds(afterRunOf: milliseconds / 1000)
        )
        guard succeeded else {
            log("personalisation: training generation \(generation) failed")
            return
        }

        let previous = publishedGeneration
        publishedGeneration = generation
        // The corpus size and the time are logged together because one explains
        // the other: training reads the whole corpus every run, so the cost
        // grows with how long the user has been using the IME. It is also what
        // decides how often retraining can afford to happen — see
        // `commitsPerTrainingRun`.
        log("personalisation: generation \(generation) published"
            + " (\(lines) lines, \(Int(milliseconds.rounded()))ms)")

        // Only once the new generation is the published one, so a converter
        // holding the old path is never left pointing at a deleted file.
        if let previous {
            try? fileManager.removeItem(at: PersonalizationLayout.generationDirectory(previous))
        }

        // ── Commits that arrived while this run was going ──────────────────
        //
        // `record` refuses to start a run while one is in flight, and the
        // one in flight had already zeroed the counter. Without this, a
        // burst of commits trains once — on whatever had accumulated when
        // the first run began — and then never again until the *next*
        // commit arrives.
        //
        // Found while measuring: forty confirmations in a row produced one
        // generation containing three lines, because training takes seconds
        // and the other thirty-seven landed inside that window. Someone
        // pasting a paragraph, or correcting the same word repeatedly, hits
        // exactly this.
        if unlearnedCommits >= PersonalizationLayout.commitsPerTrainingRun(corpusLines: corpusLines) {
            startTraining(settings: settings)
        }
    }

    // MARK: - Erasing

    /// Deletes the corpus and every trained generation (decision 0025).
    ///
    /// The base model is left alone: it is derived from nothing and contains
    /// nothing about the user, and keeping it avoids rebuilding it on the next
    /// start.
    func erase(settings: EngineSettings) {
        let names = (try? fileManager.contentsOfDirectory(
            atPath: PersonalizationLayout.directory.path
        )) ?? []
        for name in names {
            let isGeneration = PersonalizationLayout.generationNumber(fromDirectoryName: name) != nil
            let isPartial = name.hasSuffix(PersonalizationLayout.incompleteSuffix)
            guard isGeneration || isPartial else { continue }
            try? fileManager.removeItem(
                at: PersonalizationLayout.directory.appendingPathComponent(name)
            )
        }
        try? fileManager.removeItem(at: PersonalizationLayout.corpusURL)
        publishedGeneration = nil
        unlearnedCommits = 0
        // Otherwise the next commits would be judged against a corpus that no
        // longer exists, and a user who has just erased everything would keep
        // waiting 20 commits for the first retrain.
        corpusLines = 0
        log("personalisation: learning data erased")

        // The words the user registered and the text they imported are not
        // learning data and did not go anywhere — `imported.txt` is not in the
        // loop above, deliberately (decisions 0036 / 0037). But the model that
        // carried them into Zenzai's ranking has just been deleted along with
        // everything else. Rebuild it from those alone, or erasing the typing
        // history would silently take them down with it.
        let explicit = !registeredWords.isEmpty || !importedLines.isEmpty
        if settings.personalizationActive, baseIsReady, explicit, !isTraining {
            startTraining(settings: settings)
        }
    }
}
