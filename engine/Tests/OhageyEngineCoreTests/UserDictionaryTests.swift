// Tests for the user dictionary file format (decision 0026).
//
// What is at stake here is words someone typed in by hand, possibly over
// years. The format is line-oriented precisely so that one bad line costs one
// word; the tests that matter most are the ones showing the rest survive.

import XCTest
@testable import OhageyEngineCore

final class UserDictionaryTests: XCTestCase {
    // MARK: - Validation

    func testAcceptsAnOrdinaryEntry() {
        let entry = UserDictionaryEntry(reading: "おはぎー", word: "Ohagey", partOfSpeech: .properNoun)
        XCTAssertNil(UserDictionary.validate(entry))
    }

    func testRejectsEmptyFields() {
        XCTAssertEqual(
            UserDictionary.validate(UserDictionaryEntry(reading: "", word: "語")),
            .emptyReading
        )
        XCTAssertEqual(
            UserDictionary.validate(UserDictionaryEntry(reading: "  ", word: "語")),
            .emptyReading
        )
        XCTAssertEqual(
            UserDictionary.validate(UserDictionaryEntry(reading: "よみ", word: "")),
            .emptyWord
        )
    }

    /// The common mistake: typing the word into the reading field. Lookup is by
    /// kana, so such an entry would load cleanly and never match anything —
    /// far better to refuse it while the user is still looking at the dialog.
    func testRejectsAReadingThatIsNotKana() {
        for reading in ["御萩", "ohagey", "お萩ー", "123"] {
            XCTAssertEqual(
                UserDictionary.validate(UserDictionaryEntry(reading: reading, word: "語")),
                .readingIsNotKana(reading),
                "\(reading) must be refused"
            )
        }
    }

    func testAcceptsEveryFormOfKanaAReadingCanContain() {
        for reading in ["ひらがな", "カタカナ", "らーめん", "ラーメン", "ぁぃぅぇぉ", "ヴ", "ア・イ"] {
            XCTAssertNil(
                UserDictionary.validate(UserDictionaryEntry(reading: reading, word: "語")),
                "\(reading) must be accepted"
            )
        }
    }

    func testRejectsFieldsTooLongToBeAWord() {
        let long = String(repeating: "あ", count: UserDictionary.maximumFieldLength + 1)
        XCTAssertEqual(
            UserDictionary.validate(UserDictionaryEntry(reading: long, word: "語")),
            .tooLong(field: "reading", limit: UserDictionary.maximumFieldLength)
        )
        XCTAssertEqual(
            UserDictionary.validate(UserDictionaryEntry(
                reading: "よみ",
                word: String(repeating: "語", count: UserDictionary.maximumFieldLength + 1)
            )),
            .tooLong(field: "word", limit: UserDictionary.maximumFieldLength)
        )
    }

    // MARK: - Parsing

    func testParsesEntries() {
        let (entries, skipped) = UserDictionary.parse("""
        \(UserDictionary.header)
        おはぎー\tOhagey\tpropernoun
        たなか\t田中\tsurname
        """)

        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(entries, [
            UserDictionaryEntry(reading: "おはぎー", word: "Ohagey", partOfSpeech: .properNoun),
            UserDictionaryEntry(reading: "たなか", word: "田中", partOfSpeech: .surname),
        ])
    }

    func testIgnoresBlankLinesAndComments() {
        let (entries, skipped) = UserDictionary.parse("""
        \(UserDictionary.header)
        # a note someone left

        よみ\t語
        """)

        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(entries.count, 1)
    }

    /// The point of the format. A file of years of registrations must not be
    /// lost to one bad line.
    func testABadLineCostsOneWordAndNoMore() {
        let (entries, skipped) = UserDictionary.parse("""
        \(UserDictionary.header)
        よみいち\t語一
        this line has no tab at all
        御萩\t語二
        よみさん\t語三
        """)

        XCTAssertEqual(entries.map(\.word), ["語一", "語三"])
        XCTAssertEqual(skipped, [3, 4], "the malformed line and the non-kana reading, by line number")
    }

    func testAMissingPartOfSpeechFallsBack() {
        let (entries, _) = UserDictionary.parse("よみ\t語")
        XCTAssertEqual(entries.first?.partOfSpeech, PartOfSpeech.fallback)
    }

    /// A newer settings app naming a part of speech this build does not know is
    /// not a reason to drop the word — the user still wants it converted.
    func testAnUnknownPartOfSpeechFallsBackAndKeepsTheWord() {
        let (entries, skipped) = UserDictionary.parse("よみ\t語\tinterjection")
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(entries.first?.word, "語")
        XCTAssertEqual(entries.first?.partOfSpeech, PartOfSpeech.fallback)
    }

    func testPartOfSpeechIsCaseInsensitive() {
        let (entries, _) = UserDictionary.parse("よみ\t語\tProperNoun")
        XCTAssertEqual(entries.first?.partOfSpeech, .properNoun)
    }

    /// Extra fields are a later format this build does not understand. Reading
    /// the ones it does know beats refusing the line.
    func testExtraFieldsAreIgnoredRatherThanFatal() {
        let (entries, skipped) = UserDictionary.parse("よみ\t語\tnoun\tsomething\telse")
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(entries.first?.word, "語")
    }

    /// Two identical entries would put two identical candidates in the list.
    func testDuplicatesAreCollapsed() {
        let (entries, _) = UserDictionary.parse("""
        よみ\t語
        よみ\t語
        """)
        XCTAssertEqual(entries.count, 1)
    }

    /// One reading with several words is the ordinary case, not a duplicate.
    func testTheSameReadingWithDifferentWordsIsKept() {
        let (entries, _) = UserDictionary.parse("""
        よみ\t語一
        よみ\t語二
        """)
        XCTAssertEqual(entries.count, 2)
    }

    func testAnEmptyFileParsesToNothing() {
        XCTAssertTrue(UserDictionary.parse("").entries.isEmpty)
        XCTAssertTrue(UserDictionary.parse(UserDictionary.header).entries.isEmpty)
    }

    func testStopsAtTheEntryLimit() {
        let lines = (0 ..< (UserDictionary.maximumEntries + 100))
            .map { "よみ\t語\($0)" }
            .joined(separator: "\n")
        XCTAssertEqual(UserDictionary.parse(lines).entries.count, UserDictionary.maximumEntries)
    }

    func testHandlesWindowsLineEndings() {
        let (entries, skipped) = UserDictionary.parse(
            "\(UserDictionary.header)\r\nよみ\t語\r\nよみに\t語二\r\n"
        )
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(entries.count, 2)
    }

    // MARK: - Writing

    func testSerializedOutputParsesBack() {
        let original = [
            UserDictionaryEntry(reading: "おはぎー", word: "Ohagey", partOfSpeech: .properNoun),
            UserDictionaryEntry(reading: "たなか", word: "田中", partOfSpeech: .surname),
        ]

        let (parsed, skipped) = UserDictionary.parse(UserDictionary.serialize(original))

        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(parsed, original)
    }

    func testTheHeaderIsWritten() {
        XCTAssertTrue(UserDictionary.serialize([]).hasPrefix(UserDictionary.header))
    }

    /// A tab inside a field would read back as a different entry — or as a
    /// malformed line, losing the word.
    func testTabsAndNewlinesInAFieldCannotCorruptTheFile() {
        let awkward = [UserDictionaryEntry(reading: "よみ", word: "語\t二\n三")]

        let (parsed, skipped) = UserDictionary.parse(UserDictionary.serialize(awkward))

        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.word, "語 二 三")
    }

    // MARK: - Adding

    func testAddingAppends() {
        let existing = [UserDictionaryEntry(reading: "よみ", word: "語")]
        let added = UserDictionary.adding(
            UserDictionaryEntry(reading: "よみに", word: "語二"), to: existing
        )
        XCTAssertEqual(added.map(\.word), ["語", "語二"])
    }

    /// Registering the same word again is how someone corrects its part of
    /// speech. Appending would leave two identical candidates in the list.
    func testAddingTheSameWordReplacesItRatherThanDuplicating() {
        let existing = [UserDictionaryEntry(reading: "よみ", word: "語", partOfSpeech: .noun)]
        let added = UserDictionary.adding(
            UserDictionaryEntry(reading: "よみ", word: "語", partOfSpeech: .surname),
            to: existing
        )

        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.partOfSpeech, .surname)
    }

    // MARK: - The set of parts of speech

    /// Every name is round-trippable through the file, which is what the
    /// settings app writes and reads.
    func testEveryPartOfSpeechSurvivesTheFile() {
        let entries = PartOfSpeech.allCases.enumerated().map {
            UserDictionaryEntry(reading: "よみ", word: "語\($0.offset)", partOfSpeech: $0.element)
        }

        let (parsed, skipped) = UserDictionary.parse(UserDictionary.serialize(entries))

        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(parsed.map(\.partOfSpeech), PartOfSpeech.allCases)
    }

    /// ASCII and lowercase, so the file stays language-neutral and the settings
    /// app can use these as stable keys.
    func testPartOfSpeechNamesAreStableKeys() {
        for value in PartOfSpeech.allCases {
            XCTAssertEqual(value.rawValue, value.rawValue.lowercased())
            XCTAssertTrue(
                value.rawValue.allSatisfy { $0.isASCII && $0.isLetter },
                "\(value.rawValue) should be plain ASCII letters"
            )
        }
    }
}
