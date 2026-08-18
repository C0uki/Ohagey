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
    /// The four files inference reads, without their extension.
    /// </summary>
    /// <remarks>
    /// Four here and five in <see cref="BaseLanguageModelResumePaths"/>, which
    /// mirrors the engine's own split (<c>baseLanguageModelSuffixes</c> against
    /// <c>baseLanguageModelResumeSuffixes</c>). Pinned against it in
    /// SchemaAgreementTests: this list is written twice, and a disagreement
    /// would show up as personalisation silently doing nothing rather than as
    /// any kind of error.
    /// </remarks>
    public static readonly IReadOnlyList<string> BaseLanguageModelSuffixes =
        new[] { "_c_abc", "_r_xbx", "_u_abx", "_u_xbc" };

    /// <summary>
    /// The fifth file, needed to continue training from the base.
    /// </summary>
    /// <remarks>
    /// <c>SwiftTrainer(baseFilePattern:)</c> loads all five; inference reads
    /// four. The engine refuses to personalise at all without this one, because
    /// the only personal model it could otherwise build is the one measured to
    /// break 8 to 18 of 30 unrelated conversions (decision 0034).
    ///
    /// Ohagey trains and ships its own base and publishes all five. This was
    /// the file <c>Miwa-Keita/base_n5_lm</c> omitted, which is why that model
    /// was dropped from the installer.
    /// </remarks>
    public const string BaseLanguageModelResumeSuffix = "_c_bc";

    /// <summary>Prefix the engine builds the filenames from.</summary>
    public static string BaseLanguageModelPrefix => Path.Combine(ModelDirectory, "lm");

    public static IEnumerable<string> BaseLanguageModelPaths =>
        BaseLanguageModelSuffixes.Select(suffix => $"{BaseLanguageModelPrefix}{suffix}.marisa");

    /// <summary>Every file a resumed training run opens — the four plus the fifth.</summary>
    public static IEnumerable<string> BaseLanguageModelResumePaths =>
        BaseLanguageModelPaths.Append(
            $"{BaseLanguageModelPrefix}{BaseLanguageModelResumeSuffix}.marisa");

    /// <summary>
    /// True only when personalisation can actually do something.
    /// </summary>
    /// <remarks>
    /// All five files, not four. This is the question the page is really
    /// asking — "does turning the switch on change anything?" — and the engine
    /// answers it with <c>isBaseLanguageModelResumable</c>, which wants the
    /// fifth.
    ///
    /// It said four until the installer started shipping our own base. The
    /// installer fetches the five files as five independent downloads and
    /// download-model.ps1 always exits 0, so losing exactly one of them is an
    /// ordinary outcome of a flaky connection — and with four this reported
    /// "インストール済み" over an engine that was doing nothing at all. That is
    /// precisely the failure this whole section exists to make visible.
    ///
    /// A partial set is treated as missing rather than as "mostly installed",
    /// for the same reason: to the engine there is no such state.
    /// </remarks>
    public static bool IsBaseLanguageModelInstalled =>
        BaseLanguageModelResumePaths.All(File.Exists);

    public static long BaseLanguageModelSizeBytes =>
        BaseLanguageModelResumePaths.Sum(LengthOf);

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

        // A partial set is worth naming. "2 of 5 missing" points at an
        // interrupted download; "none of them" points at an install that never
        // fetched them at all. The installer downloads the five one at a time
        // and never fails the installation over one, so a partial set is a
        // perfectly ordinary thing to be looking at.
        var total = BaseLanguageModelResumePaths.Count();
        var missing = BaseLanguageModelResumePaths.Count(path => !File.Exists(path));
        var head = missing < total
            ? $"個人化用の言語モデルが揃っていません({total} 個中 {missing} 個が見つかりません)。"
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
