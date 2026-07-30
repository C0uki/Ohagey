// Wraps AzooKeyKanaKanjiConverter + Zenzai (decisions 0001 / 0008 / 0010 / 0024 / 0025).
//
// API NOTE: written against AzooKeyKanaKanjiConverter 0.8.5, the version SPM
// resolves from the `.upToNextMinor(from: "0.8.0")` pin. Upstream is pre-1.0
// and `main` has already moved on (there, prediction flags are enums and
// ZenzaiMode is top-level), so check these signatures again whenever the pin
// is raised.

import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import OhageyEngineCore

/// Serializes access to the converter while pipe connections are handled
/// concurrently.
///
/// This is `@MainActor` rather than an `actor` because upstream declares
/// `KanaKanjiConverter` as `@MainActor` — a separate actor cannot own it. The
/// serialization this type exists to provide still holds; it is just the main
/// actor doing it. Consequence for the pipe server: accept and read loops may
/// run anywhere, but every conversion call has to hop to the main actor, so the
/// process needs a live main-actor executor for the engine to make progress.
@MainActor
final class ConversionService {
    private let converter = KanaKanjiConverter()
    private var settings: EngineSettings
    private let personalModel: PersonalLanguageModel

    init(settings: EngineSettings, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.settings = settings
        self.personalModel = PersonalLanguageModel(log: log)
        personalModel.prepare()
    }

    func updateSettings(_ newSettings: EngineSettings) {
        let wasPersonalizing = settings.personalizationActive
        settings = newSettings

        // Switching learning or personalisation off is a request to stop
        // keeping the record, not just to stop consulting it (decision 0025).
        // Someone turning it off on a shared machine means the data should go.
        if wasPersonalizing, !newSettings.personalizationActive {
            personalModel.erase()
        }
    }

    /// True when neural conversion is active; false means we fell back to the
    /// dictionary-only path because the model is not installed (decision 0008).
    var isZenzaiActive: Bool { EnginePaths.isModelAvailable }

    /// Converts a hiragana reading into ranked candidates.
    func convert(reading: String, nBest: Int, precedingText: String) -> [EngineCandidate] {
        var composing = ComposingText()
        // `.direct` — the TSF layer has already resolved romaji to kana, so the
        // engine receives the reading as-is.
        composing.insertAtCursorPosition(reading, inputStyle: .direct)

        let results = converter.requestCandidates(composing, options: makeOptions(nBest: nBest))
        // `N_best` steers upstream's lattice search; it does not cap
        // `mainResults`, which also carries the special candidates (katakana,
        // romaji and single-character forms) appended after the ranked ones.
        // Verified against 0.8.5: a request for 5 came back with ~60. The
        // schema promises `n_best` is a maximum, so the cap is applied here.
        let offered = Array(results.mainResults.prefix(nBest))

        // Remembered so a later commit can be matched back to one of these.
        // Only what the client was actually shown: it cannot confirm a
        // candidate it never saw.
        remember(reading: reading, candidates: offered)

        return offered.map {
            // `score` is left at its default: upstream ranks `mainResults`
            // already, and its own value is not on a scale the client could
            // interpret. Order carries the ranking.
            EngineCandidate(text: $0.text, reading: reading)
        }
        // TODO: map per-bunsetsu segments so the client can support segment-wise
        // reconversion (`Candidate.segments` in ohagey.proto). Requires checking
        // what the pinned version exposes on its candidate type.
        // TODO: thread `precedingText` into the request once the pinned version's
        // context API is confirmed — Zenzai's prediction quality depends on it.
    }

    /// Feeds a confirmed candidate back into the learning store.
    ///
    /// Learning takes the converter's own `Candidate`, not a string:
    /// `updateLearningData` needs the dictionary entries the lattice used, and
    /// those cannot be reconstructed from the surface form. The wire protocol
    /// sends back only the text (decision 0007), so the match happens here
    /// against what we handed out.
    ///
    /// Two stores are fed here, because one of them cannot reach Zenzai.
    ///
    /// `updateLearningData` fills the converter's own learning store, which
    /// feeds the lattice — and the lattice sits *underneath* the neural model.
    /// Measured: with the model absent, confirming the second candidate moves
    /// it to first on the next conversion; with the model present, the ranking
    /// does not budge.
    ///
    /// So the commit is also recorded for the personal language model, which is
    /// the one thing upstream lets influence Zenzai's own ranking
    /// (decision 0034). That path is a corpus and a retraining run, not an
    /// immediate update, so it takes effect after a batch of commits rather
    /// than the next keystroke.
    func commit(reading: String, text: String, updateLearning: Bool) {
        defer {
            // The composition is over, so drop the converter's state for it.
            //
            // Not optional bookkeeping: `requestCandidates` keeps the previous
            // lattice and Zenzai cache, and reuses them when the next request
            // looks like a continuation. Leaving that in place makes a
            // freshly learned candidate invisible to the very next conversion,
            // which is exactly when the user expects to see it.
            converter.stopComposition()
        }

        guard updateLearning, settings.learningEnabled else { return }

        // Recorded before the candidate lookup below, and independently of it.
        // The n-gram is trained on text, so unlike `updateLearningData` it does
        // not need the converter's `Candidate` — and text the client composed
        // itself is exactly as valid a thing to learn from as a candidate we
        // offered.
        personalModel.record(text: text, settings: settings)

        guard let remembered = recentCandidates.first(where: { $0.reading == reading }),
              let candidate = remembered.candidates.first(where: { $0.text == text })
        else {
            // The text was not one of the candidates we offered for this
            // reading — the client sent something it composed itself, or the
            // conversion has aged out of the cache. There is nothing to learn
            // from that we could describe to the converter, and inventing a
            // Candidate would put entries in the learning store that the
            // dictionary never produced.
            return
        }

        converter.updateLearningData(candidate)
    }

    /// Candidates from recent conversions, so a commit can be matched back to
    /// the object the converter produced.
    ///
    /// Keyed by reading and bounded rather than holding just the last
    /// conversion: one engine serves every application (decision 0004), so
    /// another app can convert something else between a user picking a
    /// candidate and confirming it.
    private var recentCandidates: [(reading: String, candidates: [Candidate])] = []

    /// Enough for a handful of applications composing at once. Each entry is a
    /// few candidates, so the cost is negligible either way; the bound exists
    /// so a long session cannot grow it without limit.
    private static let recentCandidatesLimit = 8

    private func remember(reading: String, candidates: [Candidate]) {
        recentCandidates.removeAll { $0.reading == reading }
        recentCandidates.insert((reading: reading, candidates: candidates), at: 0)
        if recentCandidates.count > Self.recentCandidatesLimit {
            recentCandidates.removeLast(recentCandidates.count - Self.recentCandidatesLimit)
        }
    }

    private func makeOptions(nBest: Int) -> ConvertRequestOptions {
        // `withDefaultDictionary` rather than the plain initializer: it fills in
        // `dictionaryResourceURL` (bundled dictionary) and `textReplacer`
        // (emoji dictionary), both of which are required and have no sensible
        // value we could supply ourselves.
        .withDefaultDictionary(
            N_best: nBest,
            // Bool, not an enum, in 0.8.5. Prediction is off for now: the TSF
            // layer asks for conversion of a completed reading.
            // TODO: revisit once the candidate window supports predictions.
            requireJapanesePrediction: false,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            // Learning is on by default and switchable from the settings app
            // (decision 0025).
            learningType: settings.learningEnabled ? .inputAndOutput : .nothing,
            // Both point at %LOCALAPPDATA%\Ohagey\ (decision 0024).
            memoryDirectoryURL: EnginePaths.userDataDirectory,
            sharedContainerURL: EnginePaths.userDataDirectory,
            zenzaiMode: makeZenzaiMode(),
            metadata: .init(versionString: OhageyEngineVersion.string)
        )
    }

    /// Zenzai is enabled only when the weights are actually present; otherwise
    /// the engine degrades to dictionary-based conversion instead of failing
    /// (decision 0008).
    // ZenzaiMode is nested inside ConvertRequestOptions in 0.8.5, so it cannot
    // be named unqualified.
    private func makeZenzaiMode() -> ConvertRequestOptions.ZenzaiMode {
        guard EnginePaths.isModelAvailable else { return .off }
        return .on(
            weight: EnginePaths.modelURL,
            inferenceLimit: settings.zenzaiInferenceLimit,
            // No default upstream, so it has to be passed explicitly. nil until
            // enough has been committed to train on, and whenever the user has
            // switched personalisation off (decision 0034).
            personalizationMode: personalModel.personalizationMode(settings: settings)
        )
        // NOTE: `settings.backend` is deliberately not consulted here.
        // `ZenzaiMode` exposes no backend/GPU-offload field, so the compute
        // backend cannot be chosen through this API at all. It is determined by
        // which llama.cpp build the process has loaded: on Windows upstream
        // declares llama.cpp as a `.systemLibrary`, so we supply the DLL.
        // Backend selection therefore happens at engine startup via the DLL
        // search path, not per request — see decision 0028.
    }
}

enum OhageyEngineVersion {
    static let string = "0.0.1"
}

// MARK: - Request handling

/// Turns routed requests into converter calls.
///
/// The switch is exhaustive on purpose: adding a case to `EngineRequest` should
/// stop compiling here rather than silently reaching a client as an error.
extension ConversionService: EngineRequestHandling {
    func handle(_ request: EngineRequest) async throws -> EngineResponse {
        switch request {
        case .convert(let reading, let nBest, let precedingText):
            return .convert(
                candidates: convert(reading: reading, nBest: nBest, precedingText: precedingText),
                zenzaiUsed: isZenzaiActive
            )

        case .commit(let reading, let text, let updateLearning):
            commit(reading: reading, text: text, updateLearning: updateLearning)
            return .commit

        case .registerWord:
            // The user-dictionary file format is still undecided (decision
            // 0026), so there is nowhere to put the entry. Report it instead of
            // answering `.registerWord`, which would tell the settings app the
            // word was saved when it was not.
            throw EngineError(
                code: .internalError,
                message: "user dictionary is not implemented yet (decision 0026)"
            )

        case .ping:
            return .ping(
                engineVersion: OhageyEngineVersion.string,
                modelLoaded: isZenzaiActive,
                backend: settings.backend
            )
        }
    }
}
