// The settings schema (decision 0014).
//
// Settings live in the registry under HKEY_CURRENT_USER, written by the
// settings app and read here. This file holds everything about that which is
// not actually registry API calls: the value names, their types and ranges, and
// how a set of raw values becomes an `EngineSettings`.
//
// Split that way so the interpretation can be unit tested. Reading the registry
// needs Windows; deciding that a missing value means "keep the default" and an
// out-of-range one means "clamp" does not, and that is where the behaviour a
// user would notice actually lives. The Windows half is RegistrySettings.swift
// in the executable target.

import Foundation

/// A value as the settings store can hold it.
///
/// Only the two registry types the schema uses. Anything else the settings app
/// might write is not something this engine knows how to read, and is dropped
/// at the boundary rather than modelled here.
public enum SettingsValue: Equatable, Sendable {
    /// REG_DWORD. Also carries booleans, as 0 or 1.
    case number(Int)
    /// REG_SZ.
    case text(String)

    var number: Int? {
        if case .number(let value) = self { return value }
        return nil
    }

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

/// Where the settings are and what they are called.
public enum SettingsSchema {
    /// Subkey of HKEY_CURRENT_USER.
    ///
    /// Per-user rather than machine-wide: these are preferences, and one of
    /// them decides whether what you type is remembered (decision 0025), which
    /// is not something one account should set for another.
    public static let registryPath = #"Software\Ohagey"#

    /// Written by the settings app so a future reader can tell what it is
    /// looking at.
    ///
    /// The engine does not refuse a version it does not know. It cannot say
    /// what changed, and refusing would leave the user with an IME that ignores
    /// their settings entirely; reading the values it recognises and ignoring
    /// the rest degrades far better. Absent means 1 — hand-created keys and
    /// anything written before this existed.
    public static let currentVersion = 1

    public enum Key {
        public static let schemaVersion = "SchemaVersion"
        public static let learningEnabled = "LearningEnabled"
        public static let personalizationEnabled = "PersonalizationEnabled"
        /// Percent, not a fraction: the registry has no floating-point type,
        /// and a REG_SZ holding "0.15" would put decimal parsing — and its
        /// locale problems — between the user and whether their IME works.
        /// The useful range of alpha is coarse enough that whole percent is
        /// more precision than the setting deserves (decision 0034).
        public static let personalizationAlphaPercent = "PersonalizationAlphaPercent"
        public static let backend = "Backend"
        public static let zenzaiInferenceLimit = "ZenzaiInferenceLimit"
        public static let idleTimeoutSeconds = "IdleTimeoutSeconds"
    }

    /// Inference steps per request.
    ///
    /// The upper bound is the point of this: the value goes straight into
    /// Zenzai's per-conversion budget, so a hand-edited large number does not
    /// produce a better IME, it produces one that appears to hang on every
    /// keystroke. The lower bound keeps a zero from meaning "no inference at
    /// all" while Zenzai is supposedly on.
    public static let inferenceLimitRange = 1 ... 100

    /// How hard the personal model may push Zenzai's ranking, in percent.
    public static let alphaPercentRange = 0 ... 100

    /// Idle seconds before the engine exits (decision 0015).
    ///
    /// Zero disables the watchdog, which is how someone who would rather pay
    /// the memory than the first-conversion latency turns it off. The upper
    /// bound is a day — beyond that "exits when idle" is not what is happening,
    /// and zero says that more clearly.
    public static let idleTimeoutRange = 0 ... 86_400

    /// Clamps rather than rejects.
    ///
    /// An out-of-range value is someone reaching for an extreme, so the nearest
    /// legal value is closer to what they meant than the default is: a limit of
    /// 9999 means "as good as you can", and 100 delivers that. Falling back to
    /// 10 would look like the setting had been ignored.
    static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

extension EngineSettings {
    /// Builds settings from raw store values.
    ///
    /// Every value is optional and every malformed one falls back to the
    /// default for that field alone. Nothing here can throw, because there is
    /// no useful way to fail: refusing the whole set because one value is
    /// wrong would silently turn learning back on for a user who had switched
    /// it off (decision 0025), which is the one outcome this must not produce.
    public init(values: [String: SettingsValue]) {
        self.init()

        if let raw = values[SettingsSchema.Key.learningEnabled]?.number {
            learningEnabled = raw != 0
        }
        if let raw = values[SettingsSchema.Key.personalizationEnabled]?.number {
            personalizationEnabled = raw != 0
        }
        if let raw = values[SettingsSchema.Key.personalizationAlphaPercent]?.number {
            personalizationAlpha = Double(
                SettingsSchema.clamped(raw, to: SettingsSchema.alphaPercentRange)
            ) / 100
        }
        if let raw = values[SettingsSchema.Key.zenzaiInferenceLimit]?.number {
            zenzaiInferenceLimit = SettingsSchema.clamped(
                raw, to: SettingsSchema.inferenceLimitRange
            )
        }
        if let raw = values[SettingsSchema.Key.idleTimeoutSeconds]?.number {
            idleTimeoutSeconds = SettingsSchema.clamped(
                raw, to: SettingsSchema.idleTimeoutRange
            )
        }

        // A backend name this build does not know is a newer settings app, not
        // a corrupt value. Keeping the default beats discarding every other
        // setting alongside it, and the effective backend is visible in the
        // ping response either way.
        if let name = values[SettingsSchema.Key.backend]?.text,
           let parsed = Backend(rawValue: name.lowercased()) {
            backend = parsed
        }
    }

    /// Schema version the store claims, or 1 when it does not say.
    public static func schemaVersion(in values: [String: SettingsValue]) -> Int {
        values[SettingsSchema.Key.schemaVersion]?.number ?? SettingsSchema.currentVersion
    }
}
