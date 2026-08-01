// Loading the user dictionary and handing it to the converter (decision 0026).
//
// The format and the rules are in OhageyEngineCore/UserDictionary.swift. This
// is the file I/O and the part that needs the converter's own types.
//
// ── How entries reach the converter ─────────────────────────────────────────
//
// Not through `user.louds`. The converter can read a compiled LOUDS dictionary
// under that name, but building one needs `LOUDSBuilder`, which upstream keeps
// in its CLI target rather than the library — so it is not something this
// engine can call.
//
// It also accepts `importDynamicUserDict`, which takes entries in memory and
// needs no compilation step at all. Upstream's own evaluation command uses that
// path, and so does this.
//
// API NOTE: `ruby` has to be katakana. The text service sends hiragana and the
// file stores what it was given, so the conversion happens here, at the last
// possible moment. Getting this wrong produces a dictionary that loads cleanly
// and never matches anything.

import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import OhageyEngineCore

@MainActor
final class UserDictionaryStore {
    private var entries: [UserDictionaryEntry] = []

    /// Modification date of the file as of the last load.
    ///
    /// The settings app edits this file directly (decision 0013), so the engine
    /// has to notice changes it did not make. Checked before a conversion
    /// rather than watched on a thread: one `stat` is nothing beside a
    /// conversion, it cannot miss a notification, and it needs no second
    /// mechanism alongside the settings watcher.
    private var loadedModificationDate: Date?

    private let fileManager = FileManager.default
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Cost given to a registered word.
    ///
    /// Upstream's own dynamic user dictionary uses -10, and its built-in
    /// candidates sit between -14.5 and -19 (values are negative, and closer to
    /// zero wins). So a word the user registered explicitly outranks the
    /// dictionary's guesses — which is the whole point of having registered it.
    private static let entryValue: PValue = -10

    // MARK: - Loading

    /// Reads the file if it has changed since the last read.
    ///
    /// Returns true when the converter needs to be told about new contents.
    @discardableResult
    func reloadIfChanged() -> Bool {
        let url = UserDictionary.fileURL
        let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date

        // Absent file and no entries is the ordinary case for a new profile;
        // absent file *after* having had entries means it was deleted, which
        // has to reach the converter.
        guard modified != loadedModificationDate else { return false }
        loadedModificationDate = modified

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            let hadEntries = !entries.isEmpty
            entries = []
            if hadEntries { log("user dictionary: file is gone, dropping its entries") }
            return hadEntries
        }

        let (parsed, skipped) = UserDictionary.parse(contents)
        entries = parsed
        if !skipped.isEmpty {
            // Said out loud, with line numbers: silently dropping words someone
            // typed in would leave them wondering why one of them stopped
            // working.
            log("user dictionary: skipped \(skipped.count) unreadable line(s) at \(skipped.prefix(10).map(String.init).joined(separator: ", "))")
        }
        log("user dictionary: \(entries.count) entr\(entries.count == 1 ? "y" : "ies") loaded")
        return true
    }

    // MARK: - Registering

    /// Adds a word and writes the file back.
    ///
    /// Throws rather than reporting success for a word that was not stored: the
    /// settings app and the text service both show the user something based on
    /// this answer.
    func register(reading: String, word: String, partOfSpeech: String) throws {
        // Anything already on disk that this engine has not seen — the settings
        // app may have written since the last conversion — so the write below
        // does not discard it.
        reloadIfChanged()

        let entry = UserDictionaryEntry(
            reading: reading.trimmingCharacters(in: .whitespaces),
            word: word.trimmingCharacters(in: .whitespaces),
            // Absent or unrecognised falls back rather than failing: the wire
            // field is optional, and a caller that does not care about the part
            // of speech should still be able to register a word.
            partOfSpeech: PartOfSpeech(rawValue: partOfSpeech.lowercased()) ?? .fallback
        )

        if let problem = UserDictionary.validate(entry) {
            throw EngineError(code: .invalidArgument, message: problem.message)
        }

        let updated = UserDictionary.adding(entry, to: entries)
        guard updated.count <= UserDictionary.maximumEntries else {
            throw EngineError(
                code: .internalError,
                message: "the user dictionary is full (\(UserDictionary.maximumEntries) entries)"
            )
        }

        try write(updated)
        entries = updated
        log("user dictionary: registered \(entry.word.debugDescription)")
    }

    private func write(_ entries: [UserDictionaryEntry]) throws {
        let url = UserDictionary.fileURL
        do {
            try EnginePaths.ensureUserDataDirectoryExists()
            // Atomically: the settings app may be reading this file, and a
            // reader that catches it half-written would see a truncated
            // dictionary rather than an unreadable one — which parses, and so
            // looks like the user's words simply vanished.
            try UserDictionary.serialize(entries)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw EngineError(
                code: .internalError,
                message: "could not write the user dictionary: \(error)"
            )
        }

        // So the next `reloadIfChanged` does not read back what we just wrote.
        loadedModificationDate =
            (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    // MARK: - Handing them over

    /// Pushes the current entries into the converter.
    func apply(to converter: KanaKanjiConverter) {
        converter.sendToDicdataStore(
            .importDynamicUserDict(entries.map(Self.dicdataElement(for:)))
        )

        // Not optional bookkeeping, and the reason this took a while to get
        // right: `requestCandidates` keeps the previous lattice and reuses it
        // when the next request looks like a continuation. Register a word and
        // convert the same reading again, and the answer comes from a lattice
        // built before the word existed — the entry is in the store, the store
        // is queried, and the candidate still does not appear.
        //
        // The learning path has exactly this hazard and drops the state for
        // exactly this reason (see `commit`).
        converter.stopComposition()
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Surface forms of the registered words.
    ///
    /// For the personal language model, which is what carries them past Zenzai's
    /// re-ranking — the lattice cost alone does not (decision 0036).
    var words: [String] { entries.map(\.word) }

    private static func dicdataElement(for entry: UserDictionaryEntry) -> DicdataElement {
        let ids = partOfSpeechIDs(entry.partOfSpeech)
        return DicdataElement(
            word: entry.word,
            // Katakana. The converter builds its lookup keys with
            // `character.toKatakana()` and matches a dynamic entry by exact
            // string equality on `ruby`, so a hiragana reading here loads
            // cleanly and never matches anything.
            ruby: entry.reading.toKatakana(),
            cid: ids.cid,
            mid: ids.mid,
            value: entryValue
        )
    }

    /// Ohagey's part-of-speech names to the converter's numeric ids.
    ///
    /// The mapping lives here rather than in the core so that the file format
    /// does not depend on upstream's id tables: those are internal to the
    /// converter and free to change between versions, while what is written in
    /// a user's dictionary file must not.
    private static func partOfSpeechIDs(_ partOfSpeech: PartOfSpeech) -> (cid: Int, mid: Int) {
        switch partOfSpeech {
        case .noun: (CIDData.一般名詞.cid, MIDData.一般.mid)
        case .properNoun: (CIDData.固有名詞.cid, MIDData.一般.mid)
        case .personName: (CIDData.人名一般.cid, MIDData.一般.mid)
        case .surname: (CIDData.人名姓.cid, MIDData.人名姓.mid)
        case .givenName: (CIDData.人名名.cid, MIDData.人名名.mid)
        case .organization: (CIDData.固有名詞組織.cid, MIDData.組織.mid)
        case .placeName: (CIDData.地名一般.cid, MIDData.一般.mid)
        case .symbol: (CIDData.記号.cid, MIDData.一般.mid)
        }
    }
}
