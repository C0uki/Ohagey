// The settings schema, as the settings app writes it (decision 0035).
//
// ── This is the second implementation of one schema ─────────────────────────
//
// The engine reads these same values, in Swift, in
// engine/Sources/OhageyEngineCore/SettingsSchema.swift. Two implementations of
// one format can drift, and drift here is not a build error — it is a setting
// the user changes that silently does nothing.
//
// Three things keep them together, in descending order of how much they help:
//
//   1. The engine is lenient by design. A value this app writes under a name
//      the engine does not know is ignored rather than fatal, and a value the
//      engine expects but this app never writes keeps its default. So drift
//      degrades instead of breaking.
//   2. Both sides have tests pinning the value names and ranges against
//      decision 0035, so changing one without the other fails a test rather
//      than shipping.
//   3. The names live in one class here and one enum there, not scattered
//      through call sites.

using Microsoft.Win32;

namespace Ohagey.Settings.Core;

/// <summary>Where the settings live and what they are called.</summary>
public static class SettingsSchema
{
    /// <summary>Subkey of HKEY_CURRENT_USER.</summary>
    /// <remarks>
    /// Per-user rather than machine-wide: these are preferences, and one of
    /// them decides whether what you type is remembered (decision 0025).
    /// </remarks>
    public const string RegistryPath = @"Software\Ohagey";

    /// <summary>Written so a future reader can tell what it is looking at.</summary>
    public const int CurrentVersion = 1;

    public const string SchemaVersion = "SchemaVersion";
    public const string LearningEnabled = "LearningEnabled";
    public const string PersonalizationEnabled = "PersonalizationEnabled";

    /// <summary>
    /// Percent, not a fraction — the registry has no floating-point type.
    /// </summary>
    /// <remarks>
    /// A REG_SZ holding "0.15" would put decimal parsing, and its locale
    /// problems, between the user and whether their IME works. The useful
    /// range of alpha is coarse enough that whole percent is more precision
    /// than the setting deserves (decision 0034).
    ///
    /// The engine's model holds a fraction. Writing 0.15 here instead of 15
    /// would be a silent hundredfold error, which is why nothing outside this
    /// class handles the conversion.
    /// </remarks>
    public const string PersonalizationAlphaPercent = "PersonalizationAlphaPercent";

    public const string Backend = "Backend";
    public const string ZenzaiInferenceLimit = "ZenzaiInferenceLimit";

    /// <summary>Idle seconds before the engine exits. Zero disables it.</summary>
    public const string IdleTimeoutSeconds = "IdleTimeoutSeconds";

    public const int MinimumInferenceLimit = 1;
    public const int MaximumInferenceLimit = 100;
    public const int MinimumAlphaPercent = 0;
    /// <summary>azooKey-Desktop's strongest setting is 1.5.</summary>
    public const int MaximumAlphaPercent = 150;
    public const int MinimumIdleTimeoutSeconds = 0;
    public const int MaximumIdleTimeoutSeconds = 86_400;

    /// <summary>
    /// Settings that only take effect after the engine restarts
    /// (decisions 0028 / 0035).
    /// </summary>
    /// <remarks>
    /// Surfaced so the UI can say so. A user who changes the backend, sees
    /// nothing happen and is told nothing will reasonably conclude the setting
    /// is broken.
    /// </remarks>
    public static readonly IReadOnlyList<string> RequiringRestart =
        new[] { Backend, IdleTimeoutSeconds };

    internal static int Clamp(int value, int minimum, int maximum) =>
        value < minimum ? minimum : value > maximum ? maximum : value;
}

/// <summary>Inference backend for Zenzai (decisions 0010 / 0028).</summary>
public enum Backend
{
    Cpu,
    Cuda,
    Vulkan,
}

/// <summary>Everything the settings app can change about the engine.</summary>
public sealed record EngineSettings
{
    public bool LearningEnabled { get; init; } = true;

    /// <summary>Whether committed text also re-ranks Zenzai's output.</summary>
    /// <remarks>
    /// On by default since the base language model ships (decision 0034).
    ///
    /// It was off for a month because confirming one phrase cost 15 to 18 of
    /// 30 otherwise-correct conversions. That was a consequence of building
    /// the personal model from nothing rather than of the feature: trained by
    /// resuming from the base it leaves the evaluation set at 30 of 30 while
    /// still promoting the confirmed candidate. Resuming needs a five-file
    /// base, which Ohagey now trains and ships.
    ///
    /// The engine refuses to personalise at all when the base cannot be
    /// resumed from, so on a machine where the download failed this does
    /// nothing rather than doing harm.
    ///
    /// Mirrors the engine's own default, and the pair is pinned in
    /// SchemaAgreementTests: the engine keeps its default for anything this
    /// app has not written, so a disagreement shows the user one thing while
    /// the engine does another.
    /// </remarks>
    public bool PersonalizationEnabled { get; init; } = true;

    /// <summary>How hard the personal model may push Zenzai's ranking, 0–100.</summary>
    /// <remarks>
    /// Percent, matching the registry rather than the engine's fraction, so
    /// the conversion happens in exactly one place — see
    /// <see cref="SettingsSchema.PersonalizationAlphaPercent"/>.
    ///
    /// azooKey-Desktop, which ships the same converter and the same base
    /// language model, offers 50 / 100 / 150 and defaults to 100. Ohagey
    /// follows it. An earlier default of 15 was reasoned out rather than
    /// measured, and did nothing at all once Zenzai was genuinely running —
    /// see decision 0034.
    /// </remarks>
    public int PersonalizationAlphaPercent { get; init; } = 100;

    public Backend Backend { get; init; } = Backend.Cpu;
    public int ZenzaiInferenceLimit { get; init; } = 10;
    public int IdleTimeoutSeconds { get; init; } = 300;

    public static EngineSettings Default { get; } = new();

    /// <summary>
    /// Whether committed text also re-ranks Zenzai's output.
    /// </summary>
    /// <remarks>
    /// Personalisation keeps a plain-text record of committed phrases, so it
    /// cannot outlive the consent that learning represents (decision 0025).
    /// The engine enforces the same rule; expressing it here too keeps the UI
    /// from offering a combination that will not happen.
    /// </remarks>
    public bool PersonalizationActive => LearningEnabled && PersonalizationEnabled;

    /// <summary>Every value brought inside its allowed range.</summary>
    public EngineSettings Clamped() => this with
    {
        PersonalizationAlphaPercent = SettingsSchema.Clamp(
            PersonalizationAlphaPercent,
            SettingsSchema.MinimumAlphaPercent,
            SettingsSchema.MaximumAlphaPercent),
        ZenzaiInferenceLimit = SettingsSchema.Clamp(
            ZenzaiInferenceLimit,
            SettingsSchema.MinimumInferenceLimit,
            SettingsSchema.MaximumInferenceLimit),
        IdleTimeoutSeconds = SettingsSchema.Clamp(
            IdleTimeoutSeconds,
            SettingsSchema.MinimumIdleTimeoutSeconds,
            SettingsSchema.MaximumIdleTimeoutSeconds),
    };

    /// <summary>Names of the settings that changed and need a restart.</summary>
    public IReadOnlyList<string> SettingsRequiringRestart(EngineSettings previous)
    {
        var names = new List<string>();
        if (Backend != previous.Backend) names.Add(SettingsSchema.Backend);
        if (IdleTimeoutSeconds != previous.IdleTimeoutSeconds) names.Add(SettingsSchema.IdleTimeoutSeconds);
        return names;
    }
}

/// <summary>Reads and writes the settings key.</summary>
public interface ISettingsStore
{
    EngineSettings Read();
    void Write(EngineSettings settings);
}

/// <summary>The real registry.</summary>
public sealed class RegistrySettingsStore : ISettingsStore
{
    /// <summary>
    /// Reads the settings key, falling back to the default for anything
    /// missing or malformed.
    /// </summary>
    /// <remarks>
    /// Never throws for a bad value. The same rule the engine follows
    /// (decision 0035): one unreadable value must not reset the others,
    /// because doing so would show the user learning switched back on when
    /// they had switched it off.
    /// </remarks>
    public EngineSettings Read()
    {
        using var key = Registry.CurrentUser.OpenSubKey(SettingsSchema.RegistryPath);
        if (key is null) return EngineSettings.Default;

        var defaults = EngineSettings.Default;
        return new EngineSettings
        {
            LearningEnabled = ReadBool(key, SettingsSchema.LearningEnabled, defaults.LearningEnabled),
            PersonalizationEnabled = ReadBool(key, SettingsSchema.PersonalizationEnabled, defaults.PersonalizationEnabled),
            PersonalizationAlphaPercent = ReadInt(key, SettingsSchema.PersonalizationAlphaPercent, defaults.PersonalizationAlphaPercent),
            Backend = ReadBackend(key, defaults.Backend),
            ZenzaiInferenceLimit = ReadInt(key, SettingsSchema.ZenzaiInferenceLimit, defaults.ZenzaiInferenceLimit),
            IdleTimeoutSeconds = ReadInt(key, SettingsSchema.IdleTimeoutSeconds, defaults.IdleTimeoutSeconds),
        }.Clamped();
    }

    /// <summary>Writes every value, clamped.</summary>
    /// <remarks>
    /// Clamped on the way out as well as on the way in, so the engine is never
    /// handed something it will have to correct — and so the file the user
    /// could inspect says what is actually in effect.
    /// </remarks>
    public void Write(EngineSettings settings)
    {
        var value = settings.Clamped();
        using var key = Registry.CurrentUser.CreateSubKey(SettingsSchema.RegistryPath, writable: true)
            ?? throw new InvalidOperationException(
                $@"could not open HKCU\{SettingsSchema.RegistryPath} for writing");

        key.SetValue(SettingsSchema.SchemaVersion, SettingsSchema.CurrentVersion, RegistryValueKind.DWord);
        key.SetValue(SettingsSchema.LearningEnabled, value.LearningEnabled ? 1 : 0, RegistryValueKind.DWord);
        key.SetValue(SettingsSchema.PersonalizationEnabled, value.PersonalizationEnabled ? 1 : 0, RegistryValueKind.DWord);
        key.SetValue(SettingsSchema.PersonalizationAlphaPercent, value.PersonalizationAlphaPercent, RegistryValueKind.DWord);
        // Lowercase: the engine lowercases before matching, but writing the
        // canonical form keeps the key readable to a human with regedit open.
        key.SetValue(SettingsSchema.Backend, value.Backend.ToString().ToLowerInvariant(), RegistryValueKind.String);
        key.SetValue(SettingsSchema.ZenzaiInferenceLimit, value.ZenzaiInferenceLimit, RegistryValueKind.DWord);
        key.SetValue(SettingsSchema.IdleTimeoutSeconds, value.IdleTimeoutSeconds, RegistryValueKind.DWord);
    }

    private static bool ReadBool(RegistryKey key, string name, bool fallback) =>
        key.GetValue(name) is int raw ? raw != 0 : fallback;

    private static int ReadInt(RegistryKey key, string name, int fallback) =>
        key.GetValue(name) is int raw ? raw : fallback;

    private static Backend ReadBackend(RegistryKey key, Backend fallback) =>
        key.GetValue(SettingsSchema.Backend) is string name
            && Enum.TryParse<Backend>(name, ignoreCase: true, out var parsed)
                ? parsed
                : fallback;
}
