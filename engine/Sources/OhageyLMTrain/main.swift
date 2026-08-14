// Trains an n-gram language model from a text file (decision 0034, option 3).
//
// ── Why we would train our own base model ───────────────────────────────────
//
// Personalisation mixes a personal n-gram against a base one. The published
// base, `Miwa-Keita/base_n5_lm`, causes two separate problems:
//
//  1. It ships four files. `SwiftTrainer(baseFilePattern:)` loads five — it
//     also wants `_c_bc` — so the personal model cannot be trained *starting
//     from* the base. It has to be trained from nothing, which is what makes
//     the mixing term punish every word the user has not typed. Measured: 18
//     of 30 unrelated conversions lost, and correcting the mixing formula does
//     not separate the harm from the benefit (addendum of 2026-08-04).
//  2. It states no licence at all (decision 0009's addendum).
//
// A base we train ourselves fixes both: five files, and terms we set.
//
// ── Not part of the product ─────────────────────────────────────────────────
//
// A separate executable, like OhageyLMProbe. It reads a corpus and writes
// tries; it has no business being reachable from a running IME, and the
// installer ships OhageyEngine.exe alone.
//
//     swift run OhageyLMTrain <corpus.txt> <output-dir> [prefix] [--resume <prefix>]
//
// `prefix` defaults to `lm`, which is what the engine looks for beside the
// Zenzai weights (EnginePaths.baseLanguageModelPrefix). The five files are
// written as <prefix>_c_abc.marisa and so on.

import EfficientNGram
import Foundation

/// The order. Five, matching the published model and what the engine reads
/// back — a model trained at one order and read at another returns nonsense
/// rather than failing.
let ngramOrder = 5

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage: OhageyLMTrain <corpus.txt> <output-dir> [prefix] [--resume <prefix>]

      corpus.txt   one sentence per line, UTF-8
      output-dir   created if missing; five .marisa files are written into it
      prefix       filename prefix, default "lm"
      --resume     continue from an existing model rather than starting empty.
                   Needs all five files of that model, including _c_bc.
    """)
    exit(2)
}

var positional: [String] = []
var resumePrefix: String?
var index = 0
while index < arguments.count {
    if arguments[index] == "--resume" {
        guard index + 1 < arguments.count else { usage() }
        resumePrefix = arguments[index + 1]
        index += 2
    } else {
        positional.append(arguments[index])
        index += 1
    }
}

guard positional.count >= 2 else { usage() }
let corpusPath = positional[0]
let outputDirectory = positional[1]
let prefix = positional.count > 2 ? positional[2] : "lm"

guard let contents = try? String(contentsOfFile: corpusPath, encoding: .utf8) else {
    print("could not read \(corpusPath)")
    exit(1)
}

// `split(whereSeparator: \.isNewline)` rather than splitting on "\n": in Swift
// a CRLF is a single Character, so splitting on the newline scalar leaves the
// carriage return attached and, on a file written by a Windows tool, collapses
// the whole corpus into one line. That mistake has been made in this repo
// before (decision 0034).
let lines = contents.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
guard !lines.isEmpty else {
    print("\(corpusPath) has no non-empty lines")
    exit(1)
}

let characters = Set(lines.joined())
print("corpus: \(lines.count) lines, \(characters.count) distinct characters")
if let resumePrefix {
    // Reported, and checked, because getting it wrong is silent: `SwiftTrainer`
    // loads a missing trie as an empty dictionary, so a typo here trains from
    // nothing while looking exactly like a resumed run.
    let missing = ["_c_abc", "_c_bc", "_u_abx", "_u_xbc", "_r_xbx"]
        .filter { !FileManager.default.fileExists(atPath: "\(resumePrefix)\($0).marisa") }
    guard missing.isEmpty else {
        print("cannot resume from \(resumePrefix): missing \(missing.joined(separator: ", "))")
        exit(1)
    }
    print("resuming from \(resumePrefix)")
}

try? FileManager.default.createDirectory(
    atPath: outputDirectory,
    withIntermediateDirectories: true
)

let started = Date()
trainNGram(
    lines: lines,
    n: ngramOrder,
    baseFilePattern: prefix,
    outputDir: outputDirectory,
    resumeFilePattern: resumePrefix
)
let elapsed = Date().timeIntervalSince(started)

// Verified rather than assumed. A run that writes four of the five files looks
// like a success and produces a model that inference can read but training can
// never continue from — the exact situation this tool exists to get out of.
var total = 0
var missing: [String] = []
for suffix in ["_c_abc", "_c_bc", "_u_abx", "_u_xbc", "_r_xbx"] {
    let path = URL(fileURLWithPath: outputDirectory)
        .appendingPathComponent("\(prefix)\(suffix).marisa").path
    if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int {
        total += size
        print(String(format: "  %@%@.marisa  %.1f MB", prefix, suffix, Double(size) / 1_048_576))
    } else {
        missing.append(suffix)
    }
}

print(String(format: "total %.1f MB in %.1fs", Double(total) / 1_048_576, elapsed))
if !missing.isEmpty {
    print("MISSING: \(missing.joined(separator: ", "))")
    exit(1)
}
