// Engine settings and on-disk locations (decisions 0008 / 0010 / 0014 / 0024 / 0025).
//
// Settings are written by the WinUI 3 settings app into HKCU, and the engine
// reads them and watches the key for changes rather than receiving push
// notifications over IPC (decision 0014). The value names and how raw values
// become settings are in SettingsSchema.swift; reading the registry is
// RegistrySettings.swift in the executable target.

import Foundation

/// Inference backend for Zenzai (decision 0010).
///
/// `Sendable` because it travels inside `EngineResponse.ping`, which crosses
/// isolation boundaries: conversion runs on the main actor while connections
/// are served off it.
public enum Backend: String, Sendable {
    case cpu
    case cuda
    case vulkan
}

/// Everything the engine needs to build `ConvertRequestOptions`.
///
/// `Sendable` for the same reason as `Backend`: settings are read on one actor
/// and applied on another when a hot-reload lands (decision 0014).
public struct EngineSettings: Sendable, Equatable {
    /// Learning is on by default; the settings app can disable and erase it
    /// for shared machines such as school PCs (decision 0025).
    public var learningEnabled: Bool = true
    /// Whether what the user commits also re-ranks Zenzai's own output
    /// (decision 0034).
    ///
    /// Separate from `learningEnabled` because it is a different bargain: the
    /// converter's learning store is an opaque database, while this keeps a
    /// plain-text corpus of committed phrases on disk in order to retrain from
    /// it. Switching learning off switches this off too — never the reverse.
    public var personalizationEnabled: Bool = true
    /// How hard the personal model is allowed to push Zenzai's ranking.
    ///
    /// Upstream defaults to 0.5, but that assumes the base language model it
    /// ships, whose own probability for a common token cancels most of the
    /// term. Ohagey cannot ship that model — its licence is unstated — and uses
    /// a uniform base instead, against which the same alpha is far stronger.
    /// Measured on a corpus where one continuation dominated: alpha 0.5 moved
    /// it by +4.0 logits, enough to overrule the neural model outright, while
    /// 0.15 moved it by +1.2. See decision 0034.
    public var personalizationAlpha: Double = 0.15
    public var backend: Backend = .cpu
    /// Upper bound on Zenzai inference steps per request. Surfaced here so the
    /// latency/quality tradeoff is tunable without a rebuild.
    public var zenzaiInferenceLimit: Int = 10
    /// Idle seconds before the server exits when no client is connected
    /// (decision 0015).
    public var idleTimeoutSeconds: Int = 300

    public init() {}

    public static let `default` = EngineSettings()

    /// Whether committed text should re-rank Zenzai's output.
    ///
    /// Personalisation needs a record of what the user typed, so it cannot
    /// outlive the consent that learning represents (decision 0025). Expressed
    /// here rather than at each call site so a future caller cannot check only
    /// half of it.
    public var personalizationActive: Bool {
        learningEnabled && personalizationEnabled
    }

    /// `personalizationAlpha` restricted to a range that cannot do damage.
    ///
    /// A settings file is user-editable, and the value goes straight into a
    /// logit adjustment. Negative would invert the personalisation — confirming
    /// a candidate would push it *down* — and a large one drowns the neural
    /// model out entirely, which looks to the user like conversion has broken.
    public var effectivePersonalizationAlpha: Float {
        Float(min(max(personalizationAlpha, 0), 1))
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
