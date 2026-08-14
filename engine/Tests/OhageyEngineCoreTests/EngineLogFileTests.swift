import XCTest
@testable import OhageyEngineCore

final class EngineLogFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ohagey-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String = "engine.log") -> URL {
        directory.appendingPathComponent(name)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testWritesTheMessageWithATimestampAndProcessId() throws {
        let log = EngineLogFile(url: url(), processId: 4242)
        log.append("listening")
        log.close()

        let text = try contents(of: url())
        XCTAssertTrue(text.hasSuffix("[4242] listening\n"), text)
        // yyyy-MM-dd at the front, so lines sort chronologically.
        XCTAssertNotNil(text.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "#,
                                   options: .regularExpression), text)
    }

    func testAppendsRatherThanTruncating() throws {
        let first = EngineLogFile(url: url())
        first.append("first session")
        first.close()

        // A second engine process, which is the normal case: they start and
        // exit all day (decision 0015).
        let second = EngineLogFile(url: url())
        second.append("second session")
        second.close()

        let text = try contents(of: url())
        XCTAssertTrue(text.contains("first session"), text)
        XCTAssertTrue(text.contains("second session"), text)
    }

    func testCreatesTheDirectoryItNeeds() throws {
        let nested = directory
            .appendingPathComponent("not", isDirectory: true)
            .appendingPathComponent("there", isDirectory: true)
            .appendingPathComponent("engine.log")
        let log = EngineLogFile(url: nested)
        log.append("hello")
        log.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testStaysUnderTheCapAndKeepsOneRotation() throws {
        // Small enough that a handful of lines crosses it.
        let log = EngineLogFile(url: url(), maximumBytes: 400, processId: 1)
        for i in 0..<200 { log.append("line \(i) ------------------------------") }
        log.close()

        let live = url()
        let rotated = EngineLogFile.rotatedURL(for: live)

        let liveSize = try FileManager.default.attributesOfItem(atPath: live.path)[.size] as? Int
        XCTAssertNotNil(liveSize)
        XCTAssertLessThanOrEqual(liveSize!, 400)

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "the previous log should be kept, not discarded")
        let rotatedSize = try FileManager.default
            .attributesOfItem(atPath: rotated.path)[.size] as? Int
        XCTAssertLessThanOrEqual(rotatedSize ?? 0, 400)

        // The most recent lines are the ones that survive in the live file.
        XCTAssertTrue(try contents(of: live).contains("line 199"))
    }

    func testKeepsExactlyOneRotationHowManyTimesItRolls() throws {
        let log = EngineLogFile(url: url(), maximumBytes: 200, processId: 1)
        for i in 0..<500 { log.append("line \(i) ------------------------------") }
        log.close()

        let extra = url().appendingPathExtension("1").appendingPathExtension("1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra.path),
                       "rotations must not accumulate")
        let all = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(all), ["engine.log", "engine.log.1"])
    }

    func testGivesUpQuietlyWhenTheFileCannotBeOpened() throws {
        // A directory where the log should be: opening it for writing fails,
        // and the engine has to carry on converting regardless.
        let taken = url("engine.log")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)

        let log = EngineLogFile(url: taken)
        log.append("this cannot be written")
        log.append("nor this")
        log.close()
    }

    func testAppendIsSafeFromSeveralThreads() throws {
        // main.swift hands one closure to the accept loop and to every
        // connection thread, so these appends genuinely race.
        let log = EngineLogFile(url: url(), maximumBytes: 1 << 20, processId: 7)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            log.append("from \(i)")
        }
        log.close()

        let text = try contents(of: url())
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        // Every line whole: no interleaving, no partial writes.
        for line in lines {
            XCTAssertNotNil(line.range(of: #"^\S+ \S+ \[7\] from \d+$"#,
                                       options: .regularExpression), String(line))
        }
    }
}

/// The log must never become a transcript of what the user wrote.
///
/// Asserted rather than left to review: the summaries are one interpolation
/// away from carrying the reading, and nothing else in the build would notice.
final class RequestLogSummaryTests: XCTestCase {
    private let secret = "ひみつのぶんしょう"

    func testConvertNamesTheMethodAndLengthsButNotTheText() {
        let summary = EngineRequest
            .convert(reading: secret, nBest: 9, precedingText: secret)
            .logSummary
        XCTAssertFalse(summary.contains(secret), summary)
        XCTAssertTrue(summary.hasPrefix("convert "), summary)
        XCTAssertTrue(summary.contains("reading \(secret.count)"), summary)
    }

    func testCommitDoesNotCarryTheCommittedText() {
        let summary = EngineRequest
            .commit(reading: secret, text: secret, updateLearning: true)
            .logSummary
        XCTAssertFalse(summary.contains(secret), summary)
        XCTAssertTrue(summary.contains("learn true"), summary)
    }

    func testRegisterWordDoesNotCarryTheWord() {
        let summary = EngineRequest
            .registerWord(reading: secret, surface: secret, partOfSpeech: "名詞")
            .logSummary
        XCTAssertFalse(summary.contains(secret), summary)
    }

    func testCandidatesAreCountedNotListed() {
        let candidate = EngineCandidate(text: secret, reading: secret)
        let summary = EngineResponse
            .convert(candidates: [candidate, candidate], zenzaiUsed: true)
            .logSummary
        XCTAssertFalse(summary.contains(secret), summary)
        XCTAssertTrue(summary.contains("2 candidates"), summary)
    }
}

extension EngineLogFileTests {
    /// The zone is a parameter because `TimeZone.current` is GMT on Swift for
    /// Windows, and a log nine hours off with no zone printed is worse than no
    /// log. Asserted so the parameter cannot quietly stop being used.
    func testTimestampsAreInTheZoneItWasGiven() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))

        let a = EngineLogFile(url: url("tokyo.log"), processId: 1, timeZone: tokyo)
        a.append("x")
        a.close()
        let b = EngineLogFile(url: url("utc.log"), processId: 1, timeZone: utc)
        b.append("x")
        b.close()

        let hourInTokyo = try Int(XCTUnwrap(contents(of: url("tokyo.log")).dropFirst(11).prefix(2)))
        let hourInUtc = try Int(XCTUnwrap(contents(of: url("utc.log")).dropFirst(11).prefix(2)))
        XCTAssertEqual((hourInUtc! + 9) % 24, hourInTokyo!)
    }
}
