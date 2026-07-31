// The user dictionary file (decision 0026).
//
// Words the user registered explicitly, in a file under the per-user data
// directory (decision 0024). Two writers: the engine, when a `RegisterWord`
// request arrives from the text service, and the settings app, whose UI adds,
// edits and deletes entries directly.
//
// This file is the format and the rules about it. Handing entries to the
// converter needs the converter; deciding what a valid entry is does not, and
// that is what a user would notice going wrong — the same split as the settings
// schema (decision 0035).
//
// ── Why tab-separated and not JSON ──────────────────────────────────────────
//
// A JSON document with one syntax error anywhere loses every entry in it. This
// file may hold thousands of words someone typed in by hand over years, and it
// is plausibly hand-edited; losing all of them to one stray character is not an
// acceptable failure mode. A line-oriented format loses exactly the broken
// line, which is the same principle the settings schema follows for a corrupt
// value (decision 0035).
//
// It also makes importing from other IMEs cheap if that is ever picked up
// (decision 0027) — MS-IME and Google 日本語入力 both export tab-separated text.

import Foundation

/// Part of speech, as the file and the settings app name it.
///
/// Deliberately a small, closed set with ASCII keys. The converter wants a pair
/// of numeric ids that mean nothing outside it, and a file full of `1289` would
/// be unreadable and unstable across upstream versions; these names are ours
/// and the mapping to ids lives beside the converter.
public enum PartOfSpeech: String, CaseIterable, Sendable {
    case noun
    case properNoun = "propernoun"
    case personName = "personname"
    case surname
    case givenName = "givenname"
    case organization
    case placeName = "placename"
    case symbol

    /// What an entry gets when the file does not say, or says something this
    /// build does not know.
    ///
    /// A newer settings app writing a part of speech we have never heard of is
    /// not a reason to drop the word — the user still wants it converted, and a
    /// common noun is the least wrong guess.
    public static let fallback = PartOfSpeech.noun
}

/// One registered word.
public struct UserDictionaryEntry: Equatable, Sendable {
    /// How it is typed, in kana.
    public var reading: String
    /// What it converts to.
    public var word: String
    public var partOfSpeech: PartOfSpeech

    public init(reading: String, word: String, partOfSpeech: PartOfSpeech = .fallback) {
        self.reading = reading
        self.word = word
        self.partOfSpeech = partOfSpeech
    }
}

/// Why an entry was refused.
public enum UserDictionaryError: Equatable, Sendable {
    case emptyReading
    case emptyWord
    /// A reading the converter could never match. Lookup is by kana, so a
    /// reading containing kanji or latin cannot be reached by typing — the
    /// usual cause is the word having been typed into the reading field.
    case readingIsNotKana(String)
    case tooLong(field: String, limit: Int)

    public var message: String {
        switch self {
        case .emptyReading: "reading is empty"
        case .emptyWord: "word is empty"
        case .readingIsNotKana(let reading):
            "reading must be kana, and \(reading.debugDescription) is not — did the word go in the reading field?"
        case .tooLong(let field, let limit): "\(field) is longer than \(limit) characters"
        }
    }
}

public enum UserDictionary {
    /// File under the per-user data directory (decision 0024).
    public static var fileURL: URL {
        EnginePaths.userDataDirectory.appendingPathComponent("userdict.tsv")
    }

    /// First line, so a reader can tell what it is looking at and a future
    /// format change has something to branch on.
    public static let header = "#!ohagey-userdict 1"

    public static let currentVersion = 1

    /// Long enough for any real word or reading, short enough that a pasted
    /// document cannot become one entry.
    public static let maximumFieldLength = 100

    /// Bound on the file as a whole. Every entry is pushed to the converter on
    /// every reload, so an unbounded file is an unbounded startup cost.
    public static let maximumEntries = 10_000

    // MARK: - Validation

    /// Checks an entry, returning nil when it is fine.
    ///
    /// Called before writing rather than after reading: an entry that cannot
    /// work should be refused while the user is looking at the thing that
    /// refused it, not silently dropped on the next start.
    public static func validate(_ entry: UserDictionaryEntry) -> UserDictionaryError? {
        let reading = entry.reading.trimmingCharacters(in: .whitespaces)
        let word = entry.word.trimmingCharacters(in: .whitespaces)

        if reading.isEmpty { return .emptyReading }
        if word.isEmpty { return .emptyWord }
        if reading.count > maximumFieldLength {
            return .tooLong(field: "reading", limit: maximumFieldLength)
        }
        if word.count > maximumFieldLength {
            return .tooLong(field: "word", limit: maximumFieldLength)
        }
        if !isKana(reading) { return .readingIsNotKana(reading) }
        return nil
    }

    /// Hiragana, katakana, the長音 mark and the kana middle dot.
    ///
    /// The converter looks entries up by their katakana reading, so anything
    /// outside this cannot be reached by typing no matter what the user meant.
    static func isKana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            (0x3041 ... 0x3096).contains(scalar.value)   // hiragana
                || (0x30A1 ... 0x30FA).contains(scalar.value) // katakana
                || scalar.value == 0x30FC                    // ー
                || scalar.value == 0x30FB                    // ・
        }
    }

    // MARK: - Reading the file

    /// Parses the file's contents.
    ///
    /// Never throws and never gives up on the file: a line that does not parse
    /// is dropped and the rest are kept. Losing one hand-edited line should not
    /// cost someone every word they ever registered.
    ///
    /// Returns the entries it could read along with the line numbers it could
    /// not, so a caller can say how many were lost rather than pretending the
    /// file was clean.
    public static func parse(_ contents: String) -> (entries: [UserDictionaryEntry], skipped: [Int]) {
        var entries: [UserDictionaryEntry] = []
        var skipped: [Int] = []
        var seen = Set<String>()

        for (index, rawLine) in contents.split(
            omittingEmptySubsequences: false, whereSeparator: \.isNewline
        ).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Blank lines and comments — the version header is one of these.
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2 else {
                skipped.append(index + 1)
                continue
            }

            let entry = UserDictionaryEntry(
                reading: fields[0].trimmingCharacters(in: .whitespaces),
                word: fields[1].trimmingCharacters(in: .whitespaces),
                // A third field this build does not recognise falls back rather
                // than dropping the word.
                partOfSpeech: fields.count > 2
                    ? PartOfSpeech(rawValue: fields[2].trimmingCharacters(in: .whitespaces).lowercased())
                        ?? .fallback
                    : .fallback
            )

            guard validate(entry) == nil else {
                skipped.append(index + 1)
                continue
            }

            // The converter would take a duplicate as two identical candidates.
            // Keyed by reading *and* word: the same reading with two different
            // words is exactly what a user dictionary is for.
            let key = "\(entry.reading)\t\(entry.word)"
            guard seen.insert(key).inserted else { continue }

            entries.append(entry)
            if entries.count >= maximumEntries { break }
        }

        return (entries, skipped)
    }

    // MARK: - Writing the file

    /// Renders entries as the file's contents.
    ///
    /// Tabs and newlines inside a field would produce a file that reads back as
    /// something else, so they are replaced rather than escaped: an escaping
    /// scheme is one more thing a hand-editor has to know, and neither
    /// character belongs in a reading or a word.
    public static func serialize(_ entries: [UserDictionaryEntry]) -> String {
        var lines = [header]
        for entry in entries {
            lines.append([
                sanitize(entry.reading),
                sanitize(entry.word),
                entry.partOfSpeech.rawValue,
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func sanitize(_ field: String) -> String {
        field
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Adds an entry, replacing any existing one with the same reading and
    /// word.
    ///
    /// Replacing rather than appending: registering a word twice is something a
    /// user does when they want to correct its part of speech, and two entries
    /// differing only there would put two identical candidates in the list.
    public static func adding(
        _ entry: UserDictionaryEntry,
        to entries: [UserDictionaryEntry]
    ) -> [UserDictionaryEntry] {
        var updated = entries.filter {
            !($0.reading == entry.reading && $0.word == entry.word)
        }
        updated.append(entry)
        return updated
    }
}
