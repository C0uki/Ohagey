// Engine settings and on-disk locations (decisions 0008 / 0010 / 0014 / 0024 / 0025).
//
// Settings are written by the WinUI 3 settings app into the registry / a
// settings file; the engine reads them and watches for changes rather than
// receiving push notifications over IPC (decision 0014).

import Foundation

/// Inference backend for Zenzai (decision 0010).
///
/// `Sendable` because it travels inside `EngineResponse.ping`, which crosses
/// isolation boundaries: conversion runs on the main actor while connections
/// are served off it.
public enum Backend: String, Codable, Sendable {
    case cpu
    case cuda
    case vulkan
}

/// Everything the engine needs to build `ConvertRequestOptions`.
///
/// `Sendable` for the same reason as `Backend`: settings are read on one actor
/// and applied on another when a hot-reload lands (decision 0014).
public struct EngineSettings: Codable, Sendable, Equatable {
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

    /// Decodes leniently, keeping the default for anything the file does not
    /// mention.
    ///
    /// Written by hand because the synthesized `Codable` does the opposite: a
    /// missing key throws `keyNotFound`, which would fail the whole file. That
    /// failure is not contained — `load` answers it with *all* defaults, so a
    /// user whose file said only `{"learningEnabled": false}` would silently
    /// get learning switched back on (decision 0025). The settings app's schema
    /// is still unsettled (decision 0014), so a file written by a different
    /// version of it has to remain readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EngineSettings()

        learningEnabled = try container.decodeIfPresent(Bool.self, forKey: .learningEnabled)
            ?? defaults.learningEnabled
        zenzaiInferenceLimit = try container.decodeIfPresent(Int.self, forKey: .zenzaiInferenceLimit)
            ?? defaults.zenzaiInferenceLimit
        idleTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .idleTimeoutSeconds)
            ?? defaults.idleTimeoutSeconds

        // A backend name this build does not know is a newer settings app, not
        // a corrupt file. Falling back to the default beats discarding every
        // other setting alongside it; the effective backend is visible in the
        // ping response either way.
        backend = (try? container.decodeIfPresent(Backend.self, forKey: .backend))
            .flatMap { $0 } ?? defaults.backend
    }
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

    /// Environment variable that relocates the model, for development only.
    ///
    /// Exists because the shipped location needs administrator rights to write,
    /// which means without this nobody can exercise the Zenzai path on a normal
    /// developer machine. Overriding `ProgramFiles` instead does not work:
    /// Windows repopulates that variable from the registry for every new
    /// process, so a child never sees the override.
    public static let modelPathOverrideVariable = "OHAGEY_MODEL_PATH"

    /// Whether `modelPathOverrideVariable` is honored. **Debug builds only.**
    ///
    /// The engine is launched on demand by whichever client connects first
    /// (decision 0015), which means it inherits *that* application's
    /// environment. Honoring this in a shipped build would let any app in the
    /// session choose the model that the engine — shared by every other app —
    /// loads, and llama.cpp's gguf parser is not a good thing to point at an
    /// attacker-chosen file. Developers build debug, so nothing is lost by
    /// confining it there.
    public static var honorsModelPathOverride: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Machine-wide model location (decision 0008). The weights contain no
    /// user-specific data, so unlike learning data they live under Program
    /// Files and are shared by every user on the machine.
    public static var modelURL: URL {
        resolveModelURL(environment: ProcessInfo.processInfo.environment)
    }

    /// Split out from `modelURL` so both branches can be tested regardless of
    /// which configuration the tests themselves are built in.
    static func resolveModelURL(
        environment: [String: String],
        honorOverride: Bool = honorsModelPathOverride
    ) -> URL {
        if honorOverride,
           let override = environment[modelPathOverrideVariable],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let base = environment["ProgramFiles"]
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
    /// Reads settings, throwing if the file is missing or does not parse.
    ///
    /// Hot-reload needs this rather than `load`. A settings file caught
    /// mid-write does not parse, and quietly substituting defaults at that
    /// moment would silently turn learning back on for a user who had just
    /// switched it off (decision 0025) — the one thing this setting exists to
    /// prevent. The caller keeps the settings it already has instead.
    public static func decode(from url: URL = EnginePaths.settingsURL) throws -> EngineSettings {
        try JSONDecoder().decode(EngineSettings.self, from: Data(contentsOf: url))
    }

    /// Loads settings, falling back to defaults when the file is absent or
    /// unreadable. A malformed settings file must never stop the IME from
    /// starting — the user would be left unable to type.
    public static func load(from url: URL = EnginePaths.settingsURL) -> EngineSettings {
        (try? decode(from: url)) ?? .default
    }

    /// Names of the settings that changed but cannot take effect until the
    /// engine restarts.
    ///
    /// Reported rather than silently ignored: a user who flips the backend in
    /// the settings app and sees nothing happen will conclude the setting is
    /// broken. The settings app is expected to say so in its UI too
    /// (decision 0028).
    public func settingsRequiringRestart(comparedTo previous: EngineSettings) -> [String] {
        var names: [String] = []
        // The compute backend is fixed by which llama.cpp DLL the process
        // loaded at startup; nothing short of a new process can change it.
        if backend != previous.backend {
            names.append("backend")
        }
        // The watchdog's countdown is armed once, at startup.
        if idleTimeoutSeconds != previous.idleTimeoutSeconds {
            names.append("idleTimeoutSeconds")
        }
        return names
    }
}

// TODO (implementation phase):
//  - Confirm whether the settings app writes JSON here or registry values, and
//    align this type with the schema it produces (the registry schema is still
//    an open item in docs/decisions/README.md). The watcher in
//    SettingsWatcher.swift covers the file case only.
