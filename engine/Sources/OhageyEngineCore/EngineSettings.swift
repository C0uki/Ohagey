// Engine settings and on-disk locations (decisions 0008 / 0010 / 0014 / 0024 / 0025).
//
// Settings are written by the WinUI 3 settings app into the registry / a
// settings file; the engine reads them and watches for changes rather than
// receiving push notifications over IPC (decision 0014).

import Foundation

/// Inference backend for Zenzai (decision 0010).
public enum Backend: String, Codable {
    case cpu
    case cuda
    case vulkan
}

/// Everything the engine needs to build `ConvertRequestOptions`.
public struct EngineSettings: Codable {
    /// Learning is on by default; the settings app can disable and erase it
    /// for shared machines such as school PCs (decision 0025).
    public var learningEnabled: Bool = true
    public var backend: Backend = .cpu
    /// Upper bound on Zenzai inference steps per request. Surfaced here so the
    /// latency/quality tradeoff is tunable without a rebuild.
    public var zenzaiInferenceLimit: Int = 10
    /// Idle seconds before the server exits when no client is connected
    /// (decision 0015).
    public var idleTimeoutSeconds: Int = 300

    public init() {}

    public static let `default` = EngineSettings()
}

/// Filesystem locations the engine uses.
public enum EnginePaths {
    /// Per-user learning data and user dictionary (decision 0024).
    /// Passed to the converter as `memoryDirectoryURL` / `sharedContainerURL`.
    public static var userDataDirectory: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Ohagey", isDirectory: true)
    }

    /// Machine-wide model location (decision 0008). The weights contain no
    /// user-specific data, so unlike learning data they live under Program
    /// Files and are shared by every user on the machine.
    public static var modelURL: URL {
        let base = ProcessInfo.processInfo.environment["ProgramFiles"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #"C:\Program Files"#)
        return base
            .appendingPathComponent("Ohagey", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("ggml-model-Q5_K_M.gguf")
    }

    /// Settings file, written by the settings app (decision 0014).
    public static var settingsURL: URL {
        userDataDirectory.appendingPathComponent("settings.json")
    }

    /// The model download is allowed to fail at install time (decision 0008);
    /// when it is missing the engine falls back to dictionary-only conversion
    /// rather than refusing to start.
    public static var isModelAvailable: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    public static func ensureUserDataDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: userDataDirectory,
            withIntermediateDirectories: true
        )
    }
}

extension EngineSettings {
    /// Loads settings, falling back to defaults when the file is absent or
    /// unreadable. A malformed settings file must never stop the IME from
    /// working — the user would be left unable to type.
    public static func load(from url: URL = EnginePaths.settingsURL) -> EngineSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(EngineSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }
}

// TODO (implementation phase):
//  - Watch the settings file / registry key for changes and hot-reload without
//    dropping live connections (decision 0014: ReadDirectoryChangesW or
//    RegNotifyChangeKeyValue).
//  - Confirm whether the settings app writes JSON here or registry values, and
//    align this type with the schema it produces (the registry schema is still
//    an open item in docs/decisions/README.md).
//  - A backend switch may require rebuilding the converter; decide whether that
//    happens lazily on the next request or eagerly on the change notification.
