// What backend the engine is actually running (decision 0028).
//
// ── Why this is read from a file rather than asked ──────────────────────────
//
// The engine starts on demand and exits when idle (decisions 0004 / 0015), so
// almost every time this app opens there is nothing to ask. The engine writes
// what it found at startup to %LOCALAPPDATA%\Ohagey\backend-status.tsv, and
// this reads it.
//
// ── This is the third schema shared with the engine ─────────────────────────
//
// The settings key (0035) and the user dictionary (0036) are the other two, and
// the rule is the same: the names live in one place on each side, and tests pin
// them against each other. See SettingsSchema.cs.
//
// The engine's half is engine/Sources/OhageyEngineCore/BackendStatus.swift.
// Unlike the settings key, this one only ever flows engine → app, so there is
// no risk of the two writing over each other.

namespace Ohagey.Settings.Core;

/// <summary>Why the engine is on the backend it is on.</summary>
public enum BackendSelectionReason
{
    /// <summary>The requested backend loaded. The ordinary case.</summary>
    Requested,
    /// <summary>The requested backend's directory holds no llama.dll.</summary>
    NotInstalled,
    /// <summary>
    /// The DLLs are present but Windows would not load them — typically a
    /// missing vendor runtime or driver.
    /// </summary>
    LoadFailed,
    /// <summary>Nothing loaded. Conversion falls back to the dictionary.</summary>
    Unavailable,
}

/// <summary>The engine's backend selection, as of its last startup.</summary>
public sealed record BackendStatus
{
    public required Backend Requested { get; init; }

    /// <summary>What actually loaded. Null when nothing did.</summary>
    public Backend? Effective { get; init; }

    public required BackendSelectionReason Reason { get; init; }

    /// <summary>Win32 error code, when a load failed.</summary>
    public string? Detail { get; init; }

    public DateTimeOffset RecordedAt { get; init; }

    /// <summary>Whether the user is getting what they asked for.</summary>
    public bool IsHonoringRequest => Effective == Requested;
}

/// <summary>Reads the status file the engine leaves behind.</summary>
public static class BackendStatusFile
{
    public const string Filename = "backend-status.tsv";

    /// <summary>
    /// Beside the learning data: it describes this user's session, and the
    /// engine runs unelevated (decision 0024).
    /// </summary>
    public static string Path => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Ohagey",
        Filename);

    /// <summary>The recorded status, or null if there is none to read.</summary>
    /// <remarks>
    /// Never throws. A missing file is the normal state on a machine where the
    /// engine has not run yet, and an unreadable one is a diagnostic that
    /// failed — neither is worth an error dialog in a settings app.
    /// </remarks>
    public static BackendStatus? Read()
    {
        try
        {
            return File.Exists(Path) ? Parse(File.ReadAllText(Path)) : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Parses the file's contents, or null if it is not one.</summary>
    /// <remarks>
    /// Lenient about everything except the fields that carry meaning. A
    /// half-written file must not read as a working CUDA backend, but an
    /// unknown key — written by an engine newer than this app — is not worth
    /// discarding the rest over.
    /// </remarks>
    public static BackendStatus? Parse(string text)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in text.Split('\n'))
        {
            var parts = line.TrimEnd('\r').Split('\t', 2);
            if (parts.Length != 2) continue;
            values[parts[0].Trim()] = parts[1];
        }

        if (!values.TryGetValue("requested", out var requestedText)
            || ParseBackend(requestedText) is not { } requested)
        {
            return null;
        }

        if (!values.TryGetValue("reason", out var reasonText)
            || ParseReason(reasonText) is not { } reason)
        {
            return null;
        }

        values.TryGetValue("detail", out var detail);
        values.TryGetValue("effective", out var effectiveText);
        values.TryGetValue("recorded-at", out var recordedText);

        return new BackendStatus
        {
            Requested = requested,
            // An effective backend we cannot understand reads as "nothing
            // loaded". It is the one field where leniency would lie.
            Effective = effectiveText is null ? null : ParseBackend(effectiveText),
            Reason = reason,
            Detail = string.IsNullOrEmpty(detail) ? null : detail,
            RecordedAt = DateTimeOffset.TryParse(
                recordedText,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AdjustToUniversal
                    | System.Globalization.DateTimeStyles.AssumeUniversal,
                out var recorded)
                ? recorded
                : DateTimeOffset.UnixEpoch,
        };
    }

    private static Backend? ParseBackend(string text) =>
        Enum.TryParse<Backend>(text, ignoreCase: true, out var parsed) ? parsed : null;

    // Spelled out rather than parsed off the enum: the engine writes
    // kebab-case, C# names are PascalCase, and TryParse would silently accept
    // "loadfailed" while rejecting the "load-failed" that is actually written.
    private static BackendSelectionReason? ParseReason(string text) => text switch
    {
        "requested" => BackendSelectionReason.Requested,
        "not-installed" => BackendSelectionReason.NotInstalled,
        "load-failed" => BackendSelectionReason.LoadFailed,
        "unavailable" => BackendSelectionReason.Unavailable,
        _ => null,
    };
}

/// <summary>What to tell the user about the backend.</summary>
public static class BackendState
{
    /// <summary>
    /// The status line for the backend section, given what is recorded and what
    /// the settings currently say.
    /// </summary>
    /// <remarks>
    /// <paramref name="selected"/> is passed separately because the two can
    /// disagree, and that disagreement is itself worth reporting: the user may
    /// have changed the setting since the engine last started, in which case the
    /// recorded backend is stale rather than wrong. Decision 0028 asks that the
    /// UI never let a fallback pass unmentioned; it would be no better to
    /// announce one that has already been superseded.
    /// </remarks>
    public static string Describe(BackendStatus? status, Backend selected)
    {
        if (status is null)
        {
            return "変換エンジンはまだ起動していません。"
                + "文字を入力するとエンジンが起動し、実際に使われたバックエンドがここに表示されます。";
        }

        if (status.Requested != selected)
        {
            return $"設定を {Name(selected)} に変更しました。"
                + $"エンジンが次に起動したときから有効になります（前回は {Describe(status)}）。";
        }

        return Describe(status);
    }

    private static string Describe(BackendStatus status) => status.Reason switch
    {
        BackendSelectionReason.Requested =>
            $"{Name(status.Requested)} で動作しています。",

        BackendSelectionReason.NotInstalled =>
            $"{Name(status.Requested)} はインストールされていないため、"
            + $"{Name(status.Effective)} で動作しています。"
            + "インストーラーで追加してください。",

        // The error code is shown. It is the difference between a report we can
        // act on and "CUDA doesn't work".
        BackendSelectionReason.LoadFailed =>
            $"{Name(status.Requested)} を読み込めなかったため、{Name(status.Effective)} で動作しています。"
            + Explain(status.Detail),

        BackendSelectionReason.Unavailable =>
            "推論バックエンドを読み込めませんでした。"
            + "ニューラル変換 (Zenzai) は無効で、辞書のみで変換しています。"
            + Explain(status.Detail),

        _ => $"{Name(status.Effective)} で動作しています。",
    };

    /// <summary>Turns the recorded Win32 error into something actionable.</summary>
    private static string Explain(string? detail)
    {
        if (string.IsNullOrEmpty(detail)) return string.Empty;

        // 126 is the one that actually happens: the backend's own DLLs are
        // there but the vendor runtime or driver they need is not. Saying only
        // "error 126" would send the user looking in the wrong place.
        var hint = detail == "126"
            ? "必要なドライバーまたはランタイム (CUDA / Vulkan) が見つかりません。"
            : string.Empty;
        return $"{hint}(エラー {detail})";
    }

    private static string Name(Backend? backend) => backend switch
    {
        Backend.Cuda => "CUDA",
        Backend.Vulkan => "Vulkan",
        Backend.Cpu => "CPU",
        _ => "不明なバックエンド",
    };
}
