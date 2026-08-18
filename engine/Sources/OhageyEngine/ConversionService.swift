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
    private let userDictionary: UserDictionaryStore

    /// The backend whose DLLs the process actually loaded (decision 0028).
    ///
    /// Not `settings.backend`: that is what the user asked for, and it can
    /// differ when the chosen backend is not installed. Reporting the request
    /// rather than the reality would have the settings app showing CUDA while
    /// the engine runs on CPU.
    private let effectiveBackend: Backend
    private let log: @Sendable (String) -> Void

    /// Whether llama actually loaded the model, once that is known.
    ///
    /// nil until the first conversion has been through the converter, because
    /// upstream loads the weights lazily — there is nothing to report before
    /// then.
    private var zenzaiModelLoaded: Bool?

    init(
        settings: EngineSettings,
        effectiveBackend: Backend? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.settings = settings
        self.effectiveBackend = effectiveBackend ?? settings.backend
        self.log = log
        self.personalModel = PersonalLanguageModel(log: log)
        self.userDictionary = UserDictionaryStore(log: log)
        personalModel.prepare()

        userDictionary.reloadIfChanged()
        applyUserDictionary()
    }

    /// Hands the registered words to both places that need them.
    ///
    /// Two, not one, and the second is easy to forget: the lattice cost decides
    /// the order only while Zenzai is off. With the model loaded, Zenzai
    /// re-ranks above the lattice and a registered word lands wherever the
    /// neural model happens to put it — measured at 3rd, behind the reading
    /// passed straight through. The personal n-gram is the one mechanism that
    /// reaches that ranking (decisions 0034 / 0036).
    private func applyUserDictionary() {
        userDictionary.apply(to: converter)
        personalModel.updateRegisteredWords(userDictionary.words, settings: settings)
        // After the dictionary, so a first run covers both at once rather than
        // training twice. Catches the ordinary way text gets imported: with no
        // engine running, by a settings app that cannot tell one to retrain
        // (decisions 0015 / 0037).
        personalModel.trainIfNothingPublished(settings: settings)
    }

    func updateSettings(_ newSettings: EngineSettings) {
        let wasPersonalizing = settings.personalizationActive
        settings = newSettings

        // Switching learning or personalisation off is a request to stop
        // keeping the record, not just to stop consulting it (decision 0025).
        // Someone turning it off on a shared machine means the data should go.
        if wasPersonalizing, !newSettings.personalizationActive {
            personalModel.erase(settings: newSettings)
        }
    }

    /// True when neural conversion is actually happening.
    ///
    /// The file being present is not enough, and assuming it was hid a real
    /// failure for a long time: with the wrong llama.cpp build the weights are
    /// found, rejected, and every conversion quietly comes from the dictionary
    /// — while this reported Zenzai as active. `zenzaiUsed` on the wire is what
    /// the harnesses assert on, so a flag that means "the file exists" makes
    /// those assertions worthless.
    ///
    /// Before the first conversion there is nothing to know, so the intent
    /// stands in.
    var isZenzaiActive: Bool { zenzaiModelLoaded ?? EnginePaths.isModelAvailable }

    /// Reads upstream's load status once, after a conversion has had a chance
    /// to trigger it.
    ///
    /// `zenzStatus` is a display string, not a result: empty before any
    /// attempt, `"load <url>"` on success, and the same with the error appended
    /// on failure. Parsing it is unpleasant, but it is the only signal upstream
    /// offers, and the alternative is not noticing that Zenzai is off.
    private func noteZenzaiStatus() {
        guard zenzaiModelLoaded == nil, EnginePaths.isModelAvailable else { return }
        let status = converter.zenzStatus
        guard !status.isEmpty else { return }

        let loaded = status.hasPrefix("load ") && !status.contains("    ")
        zenzaiModelLoaded = loaded
        if loaded {
            log("Zenzai model loaded")
        } else {
            // Loud, because everything still appears to work: conversion keeps
            // returning candidates, just dictionary ones.
            log("Zenzai model FAILED TO LOAD — converting from the dictionary only. \(status)")
        }
    }

    /// Converts a hiragana reading into ranked candidates.
    func convert(reading: String, nBest: Int, precedingText: String) -> [EngineCandidate] {
        // The settings app edits the dictionary file directly (decision 0013),
        // so changes it made have to be picked up without an engine restart.
        // A `stat` per conversion is nothing beside the conversion itself, and
        // it cannot miss a change the way a dropped notification could.
        if userDictionary.reloadIfChanged() {
            applyUserDictionary()
        }

        // Text imported from the settings app, on the same terms and for the
        // same reason (decision 0037). Unlike the dictionary it does not need
        // to reach the converter directly — it only feeds the next training
        // run — so this starts one rather than re-applying anything.
        personalModel.refreshImportedText(settings: settings)

        // ── Why every conversion starts from nothing ───────────────────────
        //
        // `requestCandidates` keeps the previous lattice and Zenzai cache and
        // reuses them when the next request looks like a continuation of the
        // last. That is right for a keyboard feeding it one keystroke at a
        // time, and wrong here: each request on the wire carries a whole
        // reading (decision 0007), so there is no continuation to exploit —
        // only stale state to inherit.
        //
        // Measured, and the reason this is not a micro-optimisation question:
        // after confirming a candidate, converting the same reading five times
        // in a row returned rank 2, 1, 2, 1, 2. The same input, no input in
        // between, and the candidate list alternating between two orders. For a
        // user that is worse than learning not working at all — the list moves
        // under their fingers and no habit can form against it.
        //
        // Both other places that mutate what the converter knows already do
        // this for the same reason (see `commit` and `UserDictionaryStore`);
        // doing it here makes the rule general rather than a patch applied
        // wherever someone noticed.
        converter.stopComposition()

        var composing = ComposingText()
        // `.direct` — the TSF layer has already resolved romaji to kana, so the
        // engine receives the reading as-is.
        composing.insertAtCursorPosition(reading, inputStyle: .direct)

        let results = converter.requestCandidates(
            composing,
            options: makeOptions(nBest: nBest, precedingText: precedingText)
        )
        // `N_best` steers upstream's lattice search; it does not cap
        // `mainResults`, which also carries the special candidates (katakana,
        // romaji and single-character forms) appended after the ranked ones.
        // Verified against 0.8.5: a request for 5 came back with ~60. The
        // schema promises `n_best` is a maximum, so the cap is applied here.
        noteZenzaiStatus()

        let offered = Array(results.mainResults.prefix(nBest))

        // Remembered so a later commit can be matched back to one of these.
        // Only what the client was actually shown: it cannot confirm a
        // candidate it never saw.
        remember(reading: reading, candidates: offered)

        return offered.map {
            // `score` is left at its default: upstream ranks `mainResults`
            // already, and its own value is not on a scale the client could
            // interpret. Order carries the ranking.
            EngineCandidate(
                text: $0.text,
                // Not `reading`: `mainResults` mixes in candidates that convert
                // only part of the composition, and saying otherwise breaks the
                // two things this field exists for. See the helper.
                reading: EngineCandidate.reading(
                    ofRequest: reading,
                    correspondingCount: $0.correspondingCount
                )
            )
        }
        // TODO: map per-bunsetsu segments so the client can support segment-wise
        // reconversion (`Candidate.segments` in ohagey.proto). Requires checking
        // what the pinned version exposes on its candidate type.
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
            //
            // Logged, because it is a silent half-failure: personalisation
            // above still learned from this commit, the converter's own store
            // did not, and nothing else would say so. It cost a measurement —
            // a harness converting 32 unrelated readings between a conversion
            // and its commit pushed the entry out of a cache of 8, and the
            // result was read as personalisation behaving differently.
            log("commit: no remembered candidate for this reading; the converter's learning store was not updated")
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

    /// Characters of already-typed text handed to Zenzai as context.
    ///
    /// Thirty, matching azooKey-Desktop's `ContextLength.conversion`. Following
    /// a value chosen by the people who trained the model beats inventing one:
    /// too little leaves the ambiguity it was meant to resolve, and too much
    /// spends a context window that the lattice also needs.
    private static let precedingContextLength = 30

    private func remember(reading: String, candidates: [Candidate]) {
        recentCandidates.removeAll { $0.reading == reading }
        recentCandidates.insert((reading: reading, candidates: candidates), at: 0)
        if recentCandidates.count > Self.recentCandidatesLimit {
            recentCandidates.removeLast(recentCandidates.count - Self.recentCandidatesLimit)
        }
    }

    private func makeOptions(nBest: Int, precedingText: String) -> ConvertRequestOptions {
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
            zenzaiMode: makeZenzaiMode(precedingText: precedingText),
            metadata: .init(versionString: OhageyEngineVersion.string)
        )
    }

    /// Zenzai is enabled only when the weights are actually present; otherwise
    /// the engine degrades to dictionary-based conversion instead of failing
    /// (decision 0008).
    // ZenzaiMode is nested inside ConvertRequestOptions in 0.8.5, so it cannot
    // be named unqualified.
    private func makeZenzaiMode(precedingText: String) -> ConvertRequestOptions.ZenzaiMode {
        guard EnginePaths.isModelAvailable else { return .off }
        return .on(
            weight: EnginePaths.modelURL,
            inferenceLimit: settings.zenzaiInferenceLimit,
            // No default upstream, so it has to be passed explicitly. nil until
            // enough has been committed to train on, and whenever the user has
            // switched personalisation off (decision 0034).
            personalizationMode: personalModel.personalizationMode(settings: settings),
            // ── The text already on screen, handed to Zenzai ────────────────
            //
            // `precedingText` has been on the wire since the first version of
            // ohagey.proto and was going nowhere: the field arrived, and the
            // conversion was built without it. Zenzai takes it as
            // `leftSideContext` and uses it to decide between readings that are
            // ambiguous on their own — which is most of the interesting ones.
            //
            // Trimmed to the last 30 characters, matching azooKey-Desktop's
            // `ContextLength.conversion`. More is not obviously better: the
            // model has a 512-token context shared with the lattice, and the
            // sentence being typed is what disambiguates the next word.
            versionDependentMode: .v3(.init(
                leftSideContext: precedingText.isEmpty
                    ? nil
                    : String(precedingText.suffix(Self.precedingContextLength))
            ))
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

        case .registerWord(let reading, let surface, let partOfSpeech):
            try userDictionary.register(
                reading: reading,
                word: surface,
                partOfSpeech: partOfSpeech
            )
            // Straight away, so the word is available on the very next
            // conversion rather than after the file's timestamp is next
            // noticed. Registering a word and then finding it does not convert
            // is indistinguishable from it having failed.
            applyUserDictionary()
            return .registerWord

        case .ping:
            return .ping(
                engineVersion: OhageyEngineVersion.string,
                modelLoaded: isZenzaiActive,
                backend: effectiveBackend
            )
        }
    }
}
