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
    /// from the whole corpus every time. Training 10,000 lines takes about 1.8s
    /// and produces ~50 KiB, so the simplicity is nearly free — and it means
    /// erasing learning data (decision 0025) is a file deletion rather than an
    /// attempt to subtract entries from a trie.
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

    /// Drops the oldest lines so the corpus stays within `limit`.
    public static func trimmed(corpus lines: [String], limit: Int = corpusLimit) -> [String] {
        guard limit > 0 else { return [] }
        guard lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }
}
