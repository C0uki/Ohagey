// Which inference backends are actually on this machine (decision 0028).
//
// The engine picks its backend from the DLL search path, and the install ships
// one directory per backend beside the engine:
//
//     %ProgramFiles%\Ohageyackends\{cpu,cuda,vulkan}\llama.dll
//
// CPU is always there. The GPU backends are opt-in *at packaging time*
// (`iscc /DGpuBackends`), because CUDA alone is 977 MB and would take the
// installer past a gigabyte — so the ordinary download ships CPU only.
//
// ── Why the settings app has to know ────────────────────────────────────────
//
// Without this the backend list offers CUDA and Vulkan on every machine. The
// engine handles the choice correctly — it falls back to CPU and records why
// (BackendStatus.cs) — but from the user's side they picked a backend, nothing
// refused it, and nothing got faster. Offering a choice that cannot be taken
// is worse than not offering it.
//
// ── This mirrors BackendLayout.swift ────────────────────────────────────────
//
// The engine decides the same thing in
// engine/Sources/OhageyEngineCore/BackendLayout.swift, down to probing exactly
// one file. The two cannot share code across the language boundary, so what
// keeps them together is that both check `llama.dll` and nothing else: its own
// dependencies (ggml*.dll, and for CUDA the vendor runtime) sit beside it and
// resolve through the same search path. Listing them would be a second copy of
// llama.cpp's build layout, and one that goes stale.
//
// Drift here degrades rather than breaks: this file only decides what the UI
// offers, and the engine still resolves and falls back on its own.

namespace Ohagey.Settings.Core;

/// <summary>Whether a backend's DLLs are installed.</summary>
public static class BackendAvailability
{
    /// <summary>The one file whose presence means a backend is installed.</summary>
    /// <remarks>Matches BackendLayout.probeLibrary on the engine side.</remarks>
    public const string ProbeLibrary = "llama.dll";

    public const string DirectoryName = "backends";

    /// <summary>Machine-wide backend directory, beside the engine.</summary>
    public static string BackendsDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "Ohagey",
        DirectoryName);

    /// <summary>Every backend the settings app can offer.</summary>
    public static IReadOnlyList<Backend> All { get; } =
        new[] { Backend.Cpu, Backend.Cuda, Backend.Vulkan };

    /// <summary>Directory name for a backend. Lowercase, as the registry has it.</summary>
    public static string DirectoryNameFor(Backend backend) =>
        backend.ToString().ToLowerInvariant();

    /// <summary>Where a backend's DLLs would be.</summary>
    /// <param name="backendsDirectory">
    /// The directory holding one subdirectory per backend. Injected so this can
    /// be tested without an install; null means the real one.
    /// </param>
    public static string DirectoryFor(Backend backend, string? backendsDirectory = null) =>
        Path.Combine(backendsDirectory ?? BackendsDirectory, DirectoryNameFor(backend));

    /// <summary>Whether a backend looks usable.</summary>
    /// <remarks>
    /// Never throws. A settings page asks this while drawing itself, and an
    /// unreadable directory is a reason to offer less, not to fail to open.
    /// </remarks>
    public static bool IsInstalled(Backend backend, string? backendsDirectory = null)
    {
        try
        {
            return File.Exists(Path.Combine(DirectoryFor(backend, backendsDirectory), ProbeLibrary));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    /// <summary>The backends present, in the order the UI lists them.</summary>
    public static IReadOnlyList<Backend> Installed(string? backendsDirectory = null) =>
        All.Where(backend => IsInstalled(backend, backendsDirectory)).ToList();

    /// <summary>Display name, matching the combo box.</summary>
    public static string Name(Backend backend) => backend switch
    {
        Backend.Cuda => "CUDA (NVIDIA)",
        Backend.Vulkan => "Vulkan",
        _ => "CPU",
    };

    /// <summary>
    /// Why an absent backend cannot be chosen, or null when it can.
    /// </summary>
    /// <remarks>
    /// Says where it would have come from rather than only that it is missing:
    /// a user who wants CUDA can act on "the installer did not include it" and
    /// cannot act on "unavailable".
    ///
    /// CPU absent is a different sentence. It ships unconditionally, so its
    /// absence means the install is damaged rather than a choice someone made
    /// when packaging — and in that state conversion does not work at all,
    /// which the user is already seeing.
    /// </remarks>
    public static string? ExplainAbsence(Backend backend, string? backendsDirectory = null)
    {
        if (IsInstalled(backend, backendsDirectory)) return null;

        return backend == Backend.Cpu
            ? "見つかりません。おはぎーを再インストールしてください。"
            : "このインストーラーには含まれていません。GPU 版のインストーラーが必要です。";
    }
}
