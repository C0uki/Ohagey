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

    /// How many commits to gather before retraining.
    ///
    /// A compromise. Retraining per commit would spend a second of CPU on every
    /// confirmed phrase; waiting much longer makes the feature feel broken,
    /// because a user who has just corrected the same word three times expects
    /// the fourth to be right. Twenty phrases is a paragraph or two.
    private static let commitsPerTrainingRun = 20

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

    /// Creates the base model if it is not there, and reports whether it is now.
    ///
    /// Ohagey ships no base language model. Upstream's is published but carries
    /// no stated licence, so it cannot be redistributed, and it is not
    /// something the engine may go and fetch either — decision 0016 rules out
    /// network access outside installation.
    ///
    /// A base trained on nothing takes its place. That is not a degradation of
    /// the mixing so much as a change of meaning: `ZenzContext` adds
    /// `alpha * (log p_personal - log p_base)` to each logit, so a base that
    /// scores every token identically contributes the same constant everywhere.
    /// Candidates the user has never typed keep exactly the order Zenzai gave
    /// them, and only the learned ones are lifted out of it. Verified: an empty
    /// base returns 1/6000 for all 6000 tokens, spread 0.0.
    ///
    /// What it does cost is calibration. Without a real base to cancel against,
    /// a given alpha pushes much harder — hence the lower default in
    /// `EngineSettings.personalizationAlpha`.
    private func ensureBaseModel() throws -> Bool {
        if baseModelExists() { return true }

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
        guard settings.personalizationActive,
              baseIsReady,
              let generation = publishedGeneration
        else { return nil }

        return .init(
            baseNgramLanguageModel: PersonalizationLayout.basePrefix,
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
    private static let ngramOrder = 5
    private static let discount = 0.75

    // MARK: - Recording and training

    /// Records a confirmed phrase and retrains once enough have accumulated.
    func record(text: String, settings: EngineSettings) {
        guard settings.personalizationActive, baseIsReady else { return }
        guard let line = PersonalizationLayout.corpusLine(for: text) else { return }

        appendToCorpus(line)
        unlearnedCommits += 1

        guard unlearnedCommits >= Self.commitsPerTrainingRun, !isTraining else { return }
        startTraining()
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

        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let trimmed = PersonalizationLayout.trimmed(corpus: lines)
        if trimmed.count < lines.count {
            try? trimmed.joined(separator: "\n")
                .appending("\n")
                .write(to: PersonalizationLayout.corpusURL, atomically: true, encoding: .utf8)
        }
        return trimmed
    }

    private func startTraining() {
        let lines = readCorpus()
        guard !lines.isEmpty else {
            unlearnedCommits = 0
            return
        }

        let generation = (publishedGeneration ?? 0) + 1
        isTraining = true
        unlearnedCommits = 0

        // Detached, at utility priority: this is a second of CPU that must not
        // come out of the time budget for the keystroke that triggered it.
        Task.detached(priority: .utility) { [fileManager] in
            let trained = Self.train(generation: generation, lines: lines, fileManager: fileManager)
            await MainActor.run {
                self.finishTraining(generation: generation, succeeded: trained)
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
        fileManager: FileManager
    ) -> Bool {
        let staging = PersonalizationLayout.incompleteGenerationDirectory(generation)
        let destination = PersonalizationLayout.generationDirectory(generation)

        do {
            try? fileManager.removeItem(at: staging)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            trainNGram(
                lines: lines,
                n: ngramOrder,
                baseFilePattern: PersonalizationLayout.modelPattern,
                outputDir: staging.path
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

    private func finishTraining(generation: Int, succeeded: Bool) {
        isTraining = false
        guard succeeded else {
            log("personalisation: training generation \(generation) failed")
            return
        }

        let previous = publishedGeneration
        publishedGeneration = generation
        log("personalisation: generation \(generation) published")

        // Only once the new generation is the published one, so a converter
        // holding the old path is never left pointing at a deleted file.
        if let previous {
            try? fileManager.removeItem(at: PersonalizationLayout.generationDirectory(previous))
        }
    }

    // MARK: - Erasing

    /// Deletes the corpus and every trained generation (decision 0025).
    ///
    /// The base model is left alone: it is derived from nothing and contains
    /// nothing about the user, and keeping it avoids rebuilding it on the next
    /// start.
    func erase() {
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
        log("personalisation: learning data erased")
    }
}
