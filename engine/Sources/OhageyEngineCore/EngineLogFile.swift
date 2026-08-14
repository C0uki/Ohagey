// Diagnostic log file (decision 0033).
//
// ── Why this exists ─────────────────────────────────────────────────────────
//
// The engine is launched on demand by a TSF DLL living inside whatever
// application the user is typing in (decision 0015). That process has no
// console, so `print` goes nowhere: a real session on a real machine leaves
// no record whatsoever, and the only evidence available is what the user
// happened to notice. Every problem found by actually using the IME has had
// to be diagnosed without it.
//
// ── What must never go in it ────────────────────────────────────────────────
//
// **Nothing the user typed.** Not readings, not candidates, not committed
// text. A log that carried those would be a plaintext transcript of everything
// written on the machine, sitting in a file nobody remembers is there — a far
// worse thing to leave behind than the problem it was opened to diagnose. The
// engine's existing lines are counts, states and error codes, and that is the
// line to hold. Personalisation's corpus is a separate, deliberate,
// user-erasable store (decisions 0024 / 0025); this is not it.
//
// Local only, like everything else here: nothing is transmitted (decision
// 0016).
//
// ── Bounded ─────────────────────────────────────────────────────────────────
//
// The engine starts and exits many times a day (decision 0015) and appends
// across all of them, so an unbounded file grows forever on a machine nobody
// is watching. One rotation is kept: enough to cover a session that has
// already ended when the user comes to report it, and no more.

import Foundation

/// Append-only text log with a size cap and a single rotation.
///
/// Every method is best effort. A log that cannot be written is a lost
/// diagnostic; refusing to convert over it would be much worse, so failures
/// are absorbed and the process carries on without one.
public final class EngineLogFile: @unchecked Sendable {
    /// 1 MiB, which is on the order of tens of thousands of lines — months of
    /// ordinary use, and still small enough to attach to a bug report.
    public static let defaultMaximumBytes = 1 << 20

    private let url: URL
    private let maximumBytes: Int
    private let processId: Int32
    private let formatter: DateFormatter

    // The accept loop and every connection thread log (main.swift passes one
    // closure to all of them), so appends genuinely race.
    private let lock = NSLock()
    private var handle: FileHandle?
    private var bytesWritten = 0
    private var givenUp = false

    /// - Parameter timeZone: what the timestamps are in.
    ///
    ///   Passed in rather than taken from `TimeZone.current`, which **returns
    ///   GMT on Swift for Windows** — Foundation there cannot read the system
    ///   zone. Measured on this machine: `TimeZone.current.identifier` is
    ///   `GMT`, `secondsFromGMT()` is 0, while forcing `Asia/Tokyo` formats
    ///   correctly, so the zone database is present and only the *current* zone
    ///   is unavailable.
    ///
    ///   That produced the worst possible log: nine hours behind the machine
    ///   that wrote it, printed without a zone, and therefore indistinguishable
    ///   from local time. The first real session was read as 08:00 when it
    ///   happened at 17:00.
    ///
    ///   The default stays `.current` so this stays portable and honest about
    ///   what Foundation offers; `OhageyEngine` asks Windows itself and passes
    ///   the answer in (decision 0033).
    public init(
        url: URL,
        maximumBytes: Int = EngineLogFile.defaultMaximumBytes,
        processId: Int32 = ProcessInfo.processInfo.processIdentifier,
        timeZone: TimeZone = .current
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.processId = processId
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = timeZone
        // Fixed rather than inherited: under a locale with a non-Gregorian
        // calendar or non-ASCII digits, `yyyy` is not the year anyone reading
        // a log is expecting.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        self.formatter = f
    }

    /// Where the previous log is moved when the live one fills up.
    public static func rotatedURL(for url: URL) -> URL {
        url.appendingPathExtension("1")
    }

    public func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !givenUp else { return }

        let line = "\(timestamp()) [\(processId)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if handle == nil { open() }
        guard let handle else { return }

        // Rotated *before* the write that would cross the limit rather than
        // after, so the cap is a cap and not a floor.
        if bytesWritten + data.count > maximumBytes {
            rotate()
            guard let reopened = self.handle else { return }
            write(data, to: reopened)
            return
        }

        write(data, to: handle)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    // MARK: - Private

    /// The throwing API, deliberately.
    ///
    /// `FileHandle.write(_:)` — the one without `try` — is `try!` inside
    /// Foundation, so a failed write **traps the process**. That turns the
    /// worst case here from "no diagnostic" into "the IME dies while someone
    /// is typing", which is precisely backwards: this whole class is best
    /// effort because a log is worth less than conversion. A disk that has
    /// filled up, or a handle revoked underneath us, is enough to reach it.
    ///
    /// Found by `testGivesUpQuietlyWhenTheFileCannotBeOpened`, which crashed
    /// the test run: on Windows, opening a *directory* for writing succeeds
    /// and only the write fails.
    private func write(_ data: Data, to handle: FileHandle) {
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            // Not retried. Whatever stopped this write will stop the next one,
            // and a log that fails on every line would cost more than it is
            // worth.
            givenUp = true
            try? handle.close()
            self.handle = nil
        }
    }

    private func open() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                // A directory where the log goes. Opening it for writing
                // succeeds on Windows, so without this the failure only shows
                // up at the first write.
                if isDirectory.boolValue {
                    givenUp = true
                    handle = nil
                    return
                }
            } else {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: url)
            // Appended to, not truncated: the interesting session is often the
            // one before the one being watched.
            bytesWritten = Int(try opened.seekToEnd())
            handle = opened
        } catch {
            // A read-only or missing profile directory. Said once — retrying on
            // every line would turn a lost diagnostic into a stall.
            givenUp = true
            handle = nil
        }
    }

    private func rotate() {
        let fm = FileManager.default
        try? handle?.close()
        handle = nil
        bytesWritten = 0

        let rotated = Self.rotatedURL(for: url)
        try? fm.removeItem(at: rotated)
        do {
            try fm.moveItem(at: url, to: rotated)
        } catch {
            // Could not move it aside — most likely something else holds it
            // open. Truncating in place keeps the cap honest, which matters
            // more than keeping the history.
            try? Data().write(to: url)
        }
        open()
    }

    // Called under `lock`, which is what makes sharing one DateFormatter across
    // the accept loop and every connection thread safe.
    private func timestamp() -> String {
        formatter.string(from: Date())
    }
}
