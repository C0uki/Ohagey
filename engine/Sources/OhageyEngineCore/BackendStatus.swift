// What backend the engine actually ended up on, recorded for the settings app
// (decision 0028).
//
// ── Why this has to be written down at all ──────────────────────────────────
//
// Decision 0028 asks that a backend which fails to initialise falls back to CPU
// *and that the settings app say so*. The first half the engine can do alone.
// The second half it cannot: the engine starts on demand and exits when idle
// (decisions 0004 / 0015), so most of the time a user opens the settings app
// there is no engine running to ask. Whatever the engine learned about the
// machine has to outlive the process that learned it.
//
// ── Why not the registry ────────────────────────────────────────────────────
//
// HKCU\Software\Ohagey is the settings app's to write and the engine's to read
// (decision 0035), and the engine watches it for changes. Writing status into
// the same key would invert that for one value and make the engine's own writes
// indistinguishable from a user edit — it would wake itself up on its own
// notification. A file keeps the direction of every channel single.
//
// ── Format ─────────────────────────────────────────────────────────────────
//
// Tab-separated key/value lines, matching the user dictionary (decision 0036).
// Same reasons: it survives being looked at in Notepad while diagnosing
// somebody's machine, and it needs no parser on either side.
//
// Unknown keys are ignored and missing keys fall back, so an older settings app
// reading a newer engine's file degrades to showing less rather than showing
// nothing.

import Foundation

/// Why the engine is running the backend it is running.
public enum BackendSelectionReason: String, Sendable {
    /// The requested backend loaded. The ordinary case.
    case requested
    /// The requested backend's directory holds no `llama.dll`.
    case notInstalled = "not-installed"
    /// The DLLs are there but the operating system would not load them —
    /// typically a missing vendor runtime or driver.
    case loadFailed = "load-failed"
    /// Nothing loaded, not even CPU. Zenzai is unavailable and conversion falls
    /// back to the dictionary (decision 0008).
    case unavailable
}

/// The engine's backend selection, as of its last startup.
public struct BackendStatus: Sendable, Equatable {
    /// What the settings said to use.
    public var requested: Backend
    /// What the process actually loaded. Nil when nothing did.
    public var effective: Backend?
    public var reason: BackendSelectionReason
    /// The OS error, when there was one. Kept because "CUDA did not load" and
    /// "CUDA did not load, error 126" are very different amounts of help when
    /// somebody reports it.
    public var detail: String?
    public var recordedAt: Date

    public init(
        requested: Backend,
        effective: Backend?,
        reason: BackendSelectionReason,
        detail: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.requested = requested
        self.effective = effective
        self.reason = reason
        self.detail = detail
        self.recordedAt = recordedAt
    }

    /// Whether the user is getting what they asked for.
    public var isHonoringRequest: Bool { effective == requested }
}

public enum BackendStatusFile {
    public static let filename = "backend-status.tsv"
    public static let currentVersion = 1

    /// Where the engine writes it and the settings app reads it.
    ///
    /// Beside the learning data rather than in Program Files: it describes what
    /// happened in *this* user's session, and the engine runs unelevated.
    public static var url: URL {
        EnginePaths.userDataDirectory.appendingPathComponent(filename)
    }

    enum Key {
        static let version = "version"
        static let requested = "requested"
        static let effective = "effective"
        static let reason = "reason"
        static let detail = "detail"
        static let recordedAt = "recorded-at"
    }

    /// ISO 8601 in UTC. Read by C# on the other side, so the format is fixed
    /// here rather than left to whatever locale either process happens to be in.
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func serialize(_ status: BackendStatus) -> String {
        var lines = [
            "\(Key.version)\t\(currentVersion)",
            "\(Key.requested)\t\(status.requested.rawValue)",
            "\(Key.reason)\t\(status.reason.rawValue)",
            "\(Key.recordedAt)\t\(timestampFormatter.string(from: status.recordedAt))",
        ]
        // Omitted rather than written empty: an absent effective backend means
        // "nothing loaded", and a blank value would have to be special-cased to
        // mean the same thing on the reading side.
        if let effective = status.effective {
            lines.insert("\(Key.effective)\t\(effective.rawValue)", at: 2)
        }
        if let detail = status.detail, !detail.isEmpty {
            // Tabs and newlines would break the line format. The detail is an
            // OS error string that nobody parses, so flattening costs nothing.
            lines.append("\(Key.detail)\t\(sanitize(detail))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a status file, or nil if it is not one.
    ///
    /// Lenient about everything except the fields that carry meaning. A
    /// half-written file must not be reported as a working CUDA backend, but a
    /// stray line or an unknown key is not worth discarding the rest over.
    public static func parse(_ text: String) -> BackendStatus? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1])
        }

        guard let requested = values[Key.requested].flatMap(Backend.init(rawValue:)),
              let reason = values[Key.reason].flatMap(BackendSelectionReason.init(rawValue:))
        else { return nil }

        let detail = values[Key.detail]
        return BackendStatus(
            requested: requested,
            effective: values[Key.effective].flatMap(Backend.init(rawValue:)),
            reason: reason,
            detail: (detail?.isEmpty ?? true) ? nil : detail,
            // A missing or unreadable timestamp is not worth rejecting the file
            // for; it only decides how the age is phrased.
            recordedAt: values[Key.recordedAt].flatMap(timestampFormatter.date(from:)) ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func sanitize(_ detail: String) -> String {
        detail
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
