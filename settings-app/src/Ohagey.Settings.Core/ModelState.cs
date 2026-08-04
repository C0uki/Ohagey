// Whether the models are installed (decisions 0008 / 0009 / 0034).
//
// The install is allowed to complete without them — a download may fail, and
// the IME still works from the dictionary. So the settings app has to be able
// to say which of those a user is looking at, because the difference is very
// visible in conversion quality and invisible everywhere else.
//
// ── Why this is read from disk rather than from the engine ──────────────────
//
// Unlike the backend (BackendStatus.cs), nothing here needs the engine to have
// run. Whether a file is on disk is a fact this process can check for itself,
// and the models live in a machine-wide directory both processes can read. The
// backend status needs a file because only the engine can learn whether the
// DLLs actually load; model presence is not that kind of fact.

namespace Ohagey.Settings.Core;

public static class ModelState
{
    /// <summary>Machine-wide model directory (decision 0008).</summary>
    /// <remarks>
    /// Under Program Files rather than the per-user directory: the weights hold
    /// nothing user-specific, so every account on the machine shares one copy.
    /// </remarks>
    public static string ModelDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "Ohagey",
        "models");

    public static string ModelPath => Path.Combine(ModelDirectory, "ggml-model-Q5_K_M.gguf");

    public static bool IsInstalled => File.Exists(ModelPath);

    public static long SizeBytes => LengthOf(ModelPath);

    /// <summary>What to show the user about the Zenzai weights.</summary>
    public static string Describe() => IsInstalled
        ? $"インストール済み ({SizeBytes / 1024 / 1024} MB)\n{ModelPath}"
        : "未インストール。辞書のみで変換しています。\n"
          + "ニューラル変換 (Zenzai) を使うには、インストーラーからモデルを取得してください。";

    // ── The base language model (decision 0034) ─────────────────────────────
    //
    // Separate from the weights above, separately downloaded, and separately
    // able to be missing. It matters here because of how it fails: without it
    // personalisation is not weaker, it is inert. Forty confirmations of one
    // phrase moved nothing and broke nothing, against 2nd->1st and 18 of 30
    // broken with it. A user who turns the switch on and gets no effect
    // whatsoever has no way to tell that from "this feature does nothing".

    /// <summary>
    /// The four files the base model consists of, without their extension.
    /// </summary>
    /// <remarks>
    /// Four, not five. The published model has no <c>_c_bc</c>, which only a
    /// resumed training run would need — requiring it would reject a perfectly
    /// good model. Pinned against the engine in SchemaAgreementTests: this list
    /// is written twice, and a disagreement would show up as personalisation
    /// silently doing nothing rather than as any kind of error.
    /// </remarks>
    public static readonly IReadOnlyList<string> BaseLanguageModelSuffixes =
        new[] { "_c_abc", "_r_xbx", "_u_abx", "_u_xbc" };

    /// <summary>Prefix the engine builds the four filenames from.</summary>
    public static string BaseLanguageModelPrefix => Path.Combine(ModelDirectory, "lm");

    public static IEnumerable<string> BaseLanguageModelPaths =>
        BaseLanguageModelSuffixes.Select(suffix => $"{BaseLanguageModelPrefix}{suffix}.marisa");

    /// <summary>
    /// True only when every file is there — which is what the engine requires.
    /// </summary>
    /// <remarks>
    /// A partial set is treated as missing rather than as "mostly installed",
    /// because that is exactly how the engine treats it: it falls back to the
    /// empty base model, and personalisation goes inert.
    /// </remarks>
    public static bool IsBaseLanguageModelInstalled =>
        BaseLanguageModelPaths.All(File.Exists);

    public static long BaseLanguageModelSizeBytes =>
        BaseLanguageModelPaths.Sum(LengthOf);

    /// <summary>What to show about the base model, given the current setting.</summary>
    /// <remarks>
    /// <paramref name="personalizationEnabled"/> decides the wording rather
    /// than whether anything is said. Someone with the switch off is not
    /// missing anything and should not be nagged; someone with it on and no
    /// base model is getting nothing from a switch they deliberately turned on,
    /// and that is the case this exists for.
    /// </remarks>
    public static string DescribeBaseLanguageModel(bool personalizationEnabled)
    {
        if (IsBaseLanguageModelInstalled)
        {
            return personalizationEnabled
                ? $"個人化用の言語モデルはインストール済みです ({BaseLanguageModelSizeBytes / 1024 / 1024} MB)。"
                : $"個人化用の言語モデルはインストール済みです ({BaseLanguageModelSizeBytes / 1024 / 1024} MB)。"
                  + "上のスイッチを入れると使われます。";
        }

        // A partial set is worth naming. "2 of 4 missing" points at an
        // interrupted download; "none of them" points at an install that never
        // fetched them at all.
        var missing = BaseLanguageModelPaths.Count(path => !File.Exists(path));
        var head = missing < BaseLanguageModelSuffixes.Count
            ? $"個人化用の言語モデルが揃っていません({BaseLanguageModelSuffixes.Count} 個中 {missing} 個が見つかりません)。"
            : "個人化用の言語モデルがインストールされていません。";

        return personalizationEnabled
            ? head
              + "この状態ではスイッチを入れても候補順は変わりません(弱くではなく、まったく効きません)。\n"
              + $"インストーラーで取得できます。保存先: {ModelDirectory}"
            : head + "上のスイッチを入れても効果はありません。";
    }

    private static long LengthOf(string path)
    {
        try { return File.Exists(path) ? new FileInfo(path).Length : 0; }
        catch (Exception) { return 0; }
    }
}
