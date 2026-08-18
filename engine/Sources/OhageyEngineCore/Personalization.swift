// On-disk layout for the personal language model (decision 0034).
//
// Zenzai re-ranks with the neural model, so the converter's own learning store
// — which feeds the lattice underneath it — does not visibly change the order
// of candidates while the model is loaded. Upstream's mechanism for changing
// that order is `ZenzaiMode.PersonalizationMode`, which takes two n-gram
// language models as trained marisa tries: a base and a personal one.
//
// This file holds the parts of that with no dependency on the converter, so
// they can be unit tested: where the files go, which generation is usable, and
// how the corpus is bounded. The training itself is in PersonalLanguageModel.
//
// ── Why generations ─────────────────────────────────────────────────────────
//
// Loading a trie that is missing or half-written does not fail, it kills the
// process: marisa throws from C++ and nothing between there and the engine's
// main function catches it. Measured — pointing `EfficientNGram` at absent
// files exits with 0xC0000409.
//
// So a retrain never writes over the files the converter may be reading.
// Each run trains into a fresh directory and the directory is moved into place
// as a unit, which means a reader either sees the previous generation whole or
// the new one whole, and never a mixture.

import Foundation

/// Where the personal language model lives and which parts of it are usable.
public enum PersonalizationLayout {
    /// Suffixes `trainNGram` writes and `EfficientNGram` expects.
    ///
    /// Four of these are read back by inference and all five by a resumed
    /// training run, so a generation missing any one of them is unusable.
    public static let modelSuffixes = ["_c_abc", "_c_bc", "_u_abx", "_u_xbc", "_r_xbx"]

    public static let fileExtension = "marisa"

    /// Prefix `trainNGram` is given for a generation's files.
    public static let modelPattern = "model"

    /// Prefix for the base model, which sits beside the generations because it
    /// is written once and never replaced.
    public static let basePattern = "base"

    public static let generationPrefix = "gen-"

    /// Suffix marking a directory a training run has not finished with. Such a
    /// directory is never read, and is cleaned up at startup.
    public static let incompleteSuffix = ".partial"

    /// Everything for this feature, under the per-user data directory
    /// (decision 0024). Separate from the converter's own learning store so
    /// that erasing one does not have to understand the other's layout.
    public static var directory: URL {
        EnginePaths.userDataDirectory.appendingPathComponent("personal", isDirectory: true)
    }

    /// Committed text, one entry per line, oldest first.
    ///
    /// Kept rather than discarded after training because the model is retrained
    /// from the whole corpus every time. Measured at 2.7s for 10,000 lines, for
    /// ~50 KiB of output, so the simplicity is nearly free — and it means
    /// erasing learning data (decision 0025) is a file deletion rather than an
    /// attempt to subtract entries from a trie.
    ///
    /// That cost is not free of consequences, though: it is why the retraining
    /// threshold scales with this file rather than being a constant. See
    /// `commitsPerTrainingRun`.
    public static var corpusURL: URL {
        directory.appendingPathComponent("corpus.txt")
    }

    /// Upper bound on remembered lines. Beyond this the oldest are dropped.
    ///
    /// Bounds both the retraining cost and how far back the file remembers what
    /// someone typed.
    public static let corpusLimit = 10_000

    /// Longest line kept. A commit is a phrase, so anything much longer is a
    /// paste or a client bug, and would skew the model out of proportion.
    public static let maximumLineLength = 200

    public static func generationDirectory(_ generation: Int) -> URL {
        directory.appendingPathComponent("\(generationPrefix)\(generation)", isDirectory: true)
    }

    public static func incompleteGenerationDirectory(_ generation: Int) -> URL {
        directory.appendingPathComponent(
            "\(generationPrefix)\(generation)\(incompleteSuffix)",
            isDirectory: true
        )
    }

    /// Path prefix to hand `EfficientNGram(baseFilename:)` for a generation.
    public static func modelPrefix(generation: Int) -> String {
        generationDirectory(generation).appendingPathComponent(modelPattern).path
    }

    /// Path prefix for the base model.
    public static var basePrefix: String {
        directory.appendingPathComponent(basePattern).path
    }

    /// The generation a directory name denotes, or nil if it is not one.
    ///
    /// Deliberately strict: `gen-3.partial` and `gen-` and `gen-x` all have to
    /// come back nil, because anything that parses gets loaded, and loading the
    /// wrong thing takes the process down.
    public static func generationNumber(fromDirectoryName name: String) -> Int? {
        guard name.hasPrefix(generationPrefix) else { return nil }
        let digits = name.dropFirst(generationPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Filenames a complete generation contains.
    public static var modelFilenames: [String] {
        modelSuffixes.map { "\(modelPattern)\($0).\(fileExtension)" }
    }

    /// Filenames a complete base model consists of.
    public static var baseFilenames: [String] {
        modelSuffixes.map { "\(basePattern)\($0).\(fileExtension)" }
    }

    /// The newest generation with every file present.
    ///
    /// `contains` is passed in rather than reading the disk so the choice can
    /// be tested; the caller supplies a real existence check.
    ///
    /// Newest-first with a completeness test on each, rather than trusting the
    /// highest number: a run interrupted between creating a directory and
    /// filling it would otherwise be picked, and reading it is fatal.
    public static func newestCompleteGeneration(
        directoryNames: [String],
        contains: (_ generation: Int, _ filename: String) -> Bool
    ) -> Int? {
        directoryNames
            .compactMap(generationNumber(fromDirectoryName:))
            .sorted(by: >)
            .first { generation in
                modelFilenames.allSatisfy { contains(generation, $0) }
            }
    }

    /// Whether a line is worth remembering, and in a form the corpus can hold.
    ///
    /// Returns nil for anything to skip. Newlines are removed rather than
    /// rejected: the corpus is line-based, so an embedded one would turn a
    /// single commit into two entries and corrupt every line number after it.
    public static func corpusLine(for text: String) -> String? {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty, flattened.count <= maximumLineLength else { return nil }
        return flattened
    }

    // MARK: - How often to retrain

    /// Fewest commits that can trigger a training run.
    ///
    /// Three, because that is the promise the feature has to keep: someone who
    /// has corrected the same word three times expects the fourth to be right.
    /// A fixed threshold of 20 could not keep it — measured, nothing at all
    /// happened after three corrections (decision 0034).
    public static let minimumCommitsPerTrainingRun = 3

    /// Most commits to let accumulate before retraining regardless.
    ///
    /// Twenty is a paragraph or two — long enough that a heavy user's model is
    /// never far behind what they have typed, and the value the engine used
    /// unconditionally before this became adaptive.
    public static let maximumCommitsPerTrainingRun = 20

    /// Corpus lines that buy one commit's worth of delay.
    ///
    /// ── Where 50 comes from ────────────────────────────────────────────────
    ///
    /// Training reads the whole corpus every run, so its cost grows with how
    /// long someone has been using the IME. Measured on a release build
    /// (`tsf/Ohagey/tools/build-and-run-training-cost.ps1`):
    ///
    ///     100 lines    66ms      2,500 lines    747ms
    ///     500 lines   179ms      5,000 lines  1,317ms
    ///   1,000 lines   327ms     10,000 lines  2,652ms
    ///
    /// Linear past the first few hundred, about 265µs per line. So a *fixed*
    /// threshold means the background CPU spent per commit grows without bound:
    /// at 20 commits it is 3ms a commit on a new profile and 133ms on a full
    /// one. Scaling the threshold with the corpus is what holds that steady.
    ///
    /// 50 lines per commit of delay works out to roughly 15ms of background CPU
    /// per commit across the range, and puts the threshold at its 3 floor until
    /// the corpus passes 150 lines — which is where responsiveness matters
    /// most, because that is a user who is still forming an opinion.
    public static let corpusLinesPerDeferredCommit = 50

    /// How many commits to gather before retraining, for a corpus this size.
    ///
    /// The trade being made: a long-standing user goes back to waiting up to 20
    /// commits. Their model already knows a great deal, so one more correction
    /// moves it less — and the alternative is spending most of a core on
    /// retraining while they type.
    public static func commitsPerTrainingRun(corpusLines: Int) -> Int {
        let scaled = max(0, corpusLines) / corpusLinesPerDeferredCommit
        return min(maximumCommitsPerTrainingRun, max(minimumCommitsPerTrainingRun, scaled))
    }

    // MARK: - Registered words

    /// How many times a registered word is repeated in the training input.
    ///
    /// ── Why the user dictionary has to go through here at all ──────────────
    ///
    /// A registered word is given a lattice cost that beats every dictionary
    /// entry (decision 0036), and that is enough — right up until Zenzai is
    /// loaded. Zenzai re-ranks above the lattice, so the cost stops deciding the
    /// order, which is the same wall the converter's learning store hit and
    /// decision 0034 was written to get past. Measured: with Zenzai off the
    /// registered word ranks 1st, with Zenzai on it ranks 3rd, behind the
    /// reading passed straight through.
    ///
    /// So the word is also written into the training input for the personal
    /// n-gram, which is the one mechanism that does reach Zenzai's ranking.
    ///
    /// ── Why more than once ────────────────────────────────────────────────
    ///
    /// The n-gram is trained by frequency, and one line among a corpus of
    /// thousands is noise. Registering a word is not a hint — it is the user
    /// stating what they want, and it should outweigh what they happened to
    /// type. Forty is what a confirmed candidate needed to climb from 20th to
    /// 1st (decision 0034), which makes it the measured price of certainty
    /// rather than a guess.
    public static let registeredWordWeight = 40

    /// Training lines for the words a user registered explicitly.
    ///
    /// Kept separate from the corpus rather than appended to it. Two reasons,
    /// and the second is the one that matters:
    ///
    ///   1. The corpus is bounded and trimmed oldest-first, so a registered
    ///      word would eventually fall out of a dictionary it never left.
    ///   2. The corpus is a record of what someone typed and exists only with
    ///      their consent (decision 0025). A word they typed into a dictionary
    ///      editor on purpose is not that, and must keep working when they have
    ///      switched learning off.
    public static func trainingLines(forRegisteredWords words: [String]) -> [String] {
        words
            .compactMap(corpusLine(for:))
            .flatMap { Array(repeating: $0, count: registeredWordWeight) }
    }

    /// Splits a corpus file back into the lines it was written as.
    ///
    /// ── Why this is not `split(separator: "\n")` ────────────────────────────
    ///
    /// In Swift, `"\r\n"` is a *single* `Character` — one grapheme cluster —
    /// and it does not compare equal to `"\n"`. Splitting on `"\n"` therefore
    /// does not split a CRLF file at all: the whole thing comes back as one
    /// enormous line, which is then trained as a single n-gram sequence. It
    /// does not error, it does not look empty, and the only visible symptom is
    /// that personalisation quietly stops reflecting what was typed.
    ///
    /// The engine writes LF, so this only arises when something else has
    /// touched the file — opening it in Notepad to see what the IME remembers
    /// is enough, and decision 0025 is the reason a user might. Measured: a 980
    /// line CRLF corpus was read as one line.
    ///
    /// `isNewline` also covers the lone `\r` and the Unicode line separators,
    /// which cost nothing to accept here and are worse to mishandle.
    public static func corpusLines(from contents: String) -> [String] {
        contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Drops the oldest lines so the corpus stays within `limit`.
    public static func trimmed(corpus lines: [String], limit: Int = corpusLimit) -> [String] {
        guard limit > 0 else { return [] }
        guard lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }
}
