// Prints what the two language models actually say (decision 0034, addendum 12).
//
// ── Why this exists ─────────────────────────────────────────────────────────
//
// Personalisation is off by default because switching it on breaks 15 to 18 of
// 30 otherwise-correct conversions. Reading `ZenzContext` explained how that
// could happen:
//
//     baseProb     = baseLM.bulkPredict(prefix).map     { log(p + 1e-7) }
//     personalProb = personalLM.bulkPredict(prefix).map { log(p + 1e-7) }
//     logit += alpha * (personalProb - baseProb)
//
// A token the personal model has never seen scores ~0, so `log(0 + 1e-7)` pins
// it at about -16.1 while the base — trained on a great deal of text — returns
// something smoothed. The difference lands on every unseen token at once.
//
// That was arithmetic on assumed values. This measures the real ones: for a
// given prefix, how the two models' probabilities are actually distributed, and
// how large `alpha * (log p_personal - log p_base)` really gets.
//
// ── Not part of the product ─────────────────────────────────────────────────
//
// A separate executable rather than a mode of the engine. It loads models and
// prints numbers; it has no business being reachable from a running IME, and
// the installer ships OhageyEngine.exe alone.
//
//     swift run OhageyLMProbe <base-prefix> <personal-prefix> [text]
//
// The prefixes are what `EfficientNGram(baseFilename:)` takes — the path up to
// but not including `_c_abc.marisa`.

import Foundation
import EfficientNGram

/// Order of the n-gram, matching what the engine trains and loads
/// (`PersonalLanguageModel.ngramOrder`). Reading a model at a different order
/// than it was trained at returns nonsense rather than failing.
let ngramOrder = 5

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    // Raw string: the examples are Windows paths, and escaping every separator
    // would make the usage text harder to read than the thing it documents.
    print(#"""
        usage: OhageyLMProbe <base-prefix> <personal-prefix> [token-id ...]

          base-prefix      e.g. C:\swb\base_n5_lm\lm
          personal-prefix  e.g. %LOCALAPPDATA%\Ohagey\personal\gen-1\model
          token-id         context to condition on, as token ids. Omit for the
                           start of a sentence — bulkPredict pads a short
                           context with the start token, which is the state a
                           conversion begins in.

        Ids rather than text because ZenzTokenizer.encode is internal to
        EfficientNGram; only the type's initializer is public.
        """#)
    exit(2)
}

let basePrefix = arguments[1]
let personalPrefix = arguments[2]
let tokens = arguments.dropFirst(3).compactMap(Int.init)

// Same guard the engine applies before handing these to the converter: loading
// a trie whose files are missing does not throw, it takes the process down
// (decision 0034).
for prefix in [basePrefix, personalPrefix] {
    for suffix in ["_c_abc", "_r_xbx", "_u_abx", "_u_xbc"] {
        let path = "\(prefix)\(suffix).marisa"
        guard FileManager.default.fileExists(atPath: path) else {
            print("missing: \(path)")
            exit(1)
        }
    }
}

// One tokenizer for both, which is also what `ZenzContext` does — the two
// models are only comparable token by token if they were built the same way.
let tokenizer = ZenzTokenizer()
let base = EfficientNGram(baseFilename: basePrefix, n: ngramOrder, d: 0.75, tokenizer: tokenizer)
let personal = EfficientNGram(baseFilename: personalPrefix, n: ngramOrder, d: 0.75, tokenizer: tokenizer)

print("context: " + (tokens.isEmpty
    ? "start of sentence"
    : tokens.map(String.init).joined(separator: " ")))

let basePredictions = base.bulkPredict(tokens)
let personalPredictions = personal.bulkPredict(tokens)
guard basePredictions.count == personalPredictions.count else {
    print("vocabularies differ: base \(basePredictions.count), personal \(personalPredictions.count)")
    exit(1)
}

/// What `ZenzContext` does to each probability before subtracting.
func mixed(_ p: Double) -> Double { log(p + 1e-7) }

func describe(_ name: String, _ values: [Double]) {
    let sorted = values.sorted()
    let nonZero = values.filter { $0 > 1e-12 }.count
    print(String(
        format: "  %@  min %.3e  median %.3e  max %.3e   non-zero %d of %d",
        name, sorted.first ?? 0, sorted[sorted.count / 2], sorted.last ?? 0,
        nonZero, values.count
    ))
}

print("\nraw probabilities")
describe("base    ", basePredictions)
describe("personal", personalPredictions)

// The quantity that actually moves the ranking. Reported as a distribution
// rather than a single number because the damage is not one token going wrong
// — it is most of the vocabulary shifting at once.
let deltas = zip(personalPredictions, basePredictions).map { mixed($0) - mixed($1) }
let sortedDeltas = deltas.sorted()
print("\nlog p_personal - log p_base   (added to every logit, times alpha)")
print(String(format: "  min %+.2f   p25 %+.2f   median %+.2f   p75 %+.2f   max %+.2f",
             sortedDeltas.first ?? 0,
             sortedDeltas[sortedDeltas.count / 4],
             sortedDeltas[sortedDeltas.count / 2],
             sortedDeltas[3 * sortedDeltas.count / 4],
             sortedDeltas.last ?? 0))

// A conversion is decided by differences between candidates, so what matters is
// the spread across the vocabulary, not the average shift — a constant added to
// everything changes nothing (which is exactly why an empty base model did
// nothing at all; see decision 0034's revision).
let spread = (sortedDeltas.last ?? 0) - (sortedDeltas.first ?? 0)
print(String(format: "  spread %.2f logits — at alpha 1.0 that is what personalisation", spread))
print("  can move a candidate by, against Zenzai's own scores")

let boosted = deltas.filter { $0 > 0 }.count
print("\n  tokens pushed up: \(boosted) of \(deltas.count)")
print("  tokens pushed down: \(deltas.count - boosted) of \(deltas.count)")
