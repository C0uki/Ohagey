// Whether the Zenzai model is installed (decisions 0008 / 0009).
//
// The install is allowed to complete without it — the download may fail, and
// the IME still works from the dictionary. So the settings app has to be able
// to say which of those a user is looking at, because the difference is very
// visible in conversion quality and invisible everywhere else.

namespace Ohagey.Settings.Core;

public static class ModelState
{
    /// <summary>Machine-wide model location (decision 0008).</summary>
    /// <remarks>
    /// Under Program Files rather than the per-user directory: the weights hold
    /// nothing user-specific, so every account on the machine shares one copy.
    /// </remarks>
    public static string ModelPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "Ohagey",
        "models",
        "ggml-model-Q5_K_M.gguf");

    public static bool IsInstalled => File.Exists(ModelPath);

    public static long SizeBytes
    {
        get
        {
            try { return IsInstalled ? new FileInfo(ModelPath).Length : 0; }
            catch (Exception) { return 0; }
        }
    }

    /// <summary>What to show the user about the model.</summary>
    public static string Describe() => IsInstalled
        ? $"インストール済み ({SizeBytes / 1024 / 1024} MB)\n{ModelPath}"
        : "未インストール。辞書のみで変換しています。\n"
          + "ニューラル変換 (Zenzai) を使うには、インストーラーからモデルを取得してください。";
}
