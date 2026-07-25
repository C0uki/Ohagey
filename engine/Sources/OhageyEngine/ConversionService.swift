// Wraps AzooKeyKanaKanjiConverter + Zenzai (decisions 0001 / 0008 / 0010 / 0024 / 0025).
//
// ⚠️ API-DRIFT WARNING: the call shapes below were written against the
// AzooKeyKanaKanjiConverter sources on `main`, while Package.swift pins
// `.upToNextMinor(from: "0.8.0")`. Upstream is pre-1.0 and its API moves, so
// every signature here must be checked against the pinned version on the first
// real build. Parameters that could not be confirmed are marked TODO rather
// than guessed.

import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Serializes access to the converter, which is not documented as thread-safe,
/// while pipe connections are handled concurrently.
actor ConversionService {
    private let converter = KanaKanjiConverter.withDefaultDictionary()
    private var settings: EngineSettings

    init(settings: EngineSettings) {
        self.settings = settings
    }

    func updateSettings(_ newSettings: EngineSettings) {
        settings = newSettings
    }

    /// True when neural conversion is active; false means we fell back to the
    /// dictionary-only path because the model is not installed (decision 0008).
    var isZenzaiActive: Bool { EnginePaths.isModelAvailable }

    /// Converts a hiragana reading into ranked candidates.
    func convert(reading: String, nBest: Int, precedingText: String) -> [ConvertedCandidate] {
        var composing = ComposingText()
        // `.direct` — the TSF layer has already resolved romaji to kana, so the
        // engine receives the reading as-is.
        composing.insertAtCursorPosition(reading, inputStyle: .direct)

        let results = converter.requestCandidates(composing, options: makeOptions(nBest: nBest))
        return results.mainResults.map {
            ConvertedCandidate(text: $0.text, reading: reading)
        }
        // TODO: map per-bunsetsu segments so the client can support segment-wise
        // reconversion (`Candidate.segments` in ohagey.proto). Requires checking
        // what the pinned version exposes on its candidate type.
        // TODO: thread `precedingText` into the request once the pinned version's
        // context API is confirmed — Zenzai's prediction quality depends on it.
    }

    /// Feeds a confirmed candidate back into the learning store.
    func commit(reading: String, text: String, updateLearning: Bool) {
        guard updateLearning, settings.learningEnabled else { return }
        // TODO: call the pinned version's learning/update entry point
        // (`updateLearningData` or equivalent) once its signature is confirmed.
    }

    private func makeOptions(nBest: Int) -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: nBest,
            requireJapanesePrediction: .auto,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            // Learning is on by default and switchable from the settings app
            // (decision 0025).
            learningType: settings.learningEnabled ? .inputAndOutput : .nothing,
            // Both point at %LOCALAPPDATA%\Ohagey\ (decision 0024).
            memoryDirectoryURL: EnginePaths.userDataDirectory,
            sharedContainerURL: EnginePaths.userDataDirectory,
            // TODO: confirm the required `textReplacer` and
            // `specialCandidateProviders` arguments for the pinned version —
            // they have no defaults in the upstream initializer.
            zenzaiMode: makeZenzaiMode(),
            metadata: .init(versionString: OhageyEngineVersion.string)
        )
    }

    /// Zenzai is enabled only when the weights are actually present; otherwise
    /// the engine degrades to dictionary-based conversion instead of failing
    /// (decision 0008).
    private func makeZenzaiMode() -> ZenzaiMode {
        guard EnginePaths.isModelAvailable else { return .off }
        return .on(
            weight: EnginePaths.modelURL,
            inferenceLimit: settings.zenzaiInferenceLimit,
            personalizationMode: nil
        )
        // ⚠️ decision 0010 (user-selectable CPU / CUDA / Vulkan) is NOT wired up
        // here. Upstream selects the compute backend with a *package trait*
        // ("Zenzai" for GPU, "ZenzaiCPU" for CPU-only) — a build-time choice,
        // not a runtime one — so `settings.backend` currently has no effect.
        // Reconciling this needs a decision; see docs/roadmap.md.
    }
}

/// Engine-side candidate, independent of both the converter's types and the
/// generated Protobuf types so the mapping stays in one place.
struct ConvertedCandidate {
    var text: String
    var reading: String
}

enum OhageyEngineVersion {
    static let string = "0.0.1"
}
