// Erasing what the IME has learned (decisions 0025 / 0034).
//
// ── What this does and does not delete ──────────────────────────────────────
//
// Deletes:
//   memory.*                the converter's learning store (decision 0024)
//   personal/corpus.txt     committed phrases kept to retrain from (0034)
//   personal/gen-*/         models trained from that corpus (0034)
//
// Leaves alone:
//   userdict.tsv            words the user registered *deliberately* (0026).
//                           Deleting these under a button labelled "erase what
//                           has been learned" would take away work the user
//                           did on purpose, which is not what they asked for.
//   personal/imported.txt   text the user handed over deliberately (0037).
//                           Same reasoning as the dictionary, and the same
//                           trap avoided: it is in the personal/ directory
//                           with the corpus and the generations, so the
//                           obvious implementation of "erase personal/" would
//                           take it. IsPersonalArtefact names what goes rather
//                           than what stays, which is why adding a file here
//                           does not silently make it deletable.
//   personal/base_*.marisa  an empty model derived from nothing. It contains
//                           nothing about anyone, and keeping it saves
//                           rebuilding it on the next start (0034).
//
// ── The engine may be holding these files ───────────────────────────────────
//
// One engine serves the whole session and may be running right now with these
// files mapped. A delete can therefore fail, and the caller is told which files
// survived rather than being shown a success message over a directory that
// still has the data in it.
//
// Turning learning off does not need this path: the engine watches the
// settings key, and erases its own personalisation data when the setting flips
// (decision 0025). This is for erasing *without* turning learning off.

namespace Ohagey.Settings.Core;

/// <summary>What an erase actually managed to remove.</summary>
public sealed record EraseResult(
    IReadOnlyList<string> Removed,
    IReadOnlyList<string> Failed)
{
    public bool Complete => Failed.Count == 0;
}

public static class LearningData
{
    /// <summary>Per-user data directory (decision 0024).</summary>
    public static string DataDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Ohagey");

    /// <summary>Where personalisation keeps its corpus and trained models (decision 0034).</summary>
    public static string PersonalDirectory => Path.Combine(DataDirectory, "personal");

    /// <summary>
    /// Whether a name inside the data directory is part of what "erase" covers.
    /// </summary>
    /// <remarks>
    /// Split out so the rule can be tested without a filesystem, and so that
    /// the one decision worth getting right — that the user dictionary is not
    /// learning data — is stated in one place.
    /// </remarks>
    public static bool IsLearningArtefact(string name) =>
        name.StartsWith("memory.", StringComparison.OrdinalIgnoreCase);

    /// <summary>Whether a name inside <c>personal/</c> should be removed.</summary>
    public static bool IsPersonalArtefact(string name) =>
        string.Equals(name, "corpus.txt", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("gen-", StringComparison.OrdinalIgnoreCase);

    /// <summary>Roughly how much there is to erase, for the UI to show.</summary>
    /// <remarks>
    /// Shown before the button is pressed. "Erase" is not undoable, and a
    /// number is the cheapest way to tell someone whether they are about to
    /// throw away a session's worth of typing or a year's.
    /// </remarks>
    public static long EstimateBytes(string? dataDirectory = null)
    {
        var root = dataDirectory ?? DataDirectory;
        if (!Directory.Exists(root)) return 0;

        long total = 0;
        foreach (var path in SafeEnumerateFiles(root))
        {
            if (!IsLearningArtefact(Path.GetFileName(path))) continue;
            total += SafeLength(path);
        }

        var personal = Path.Combine(root, "personal");
        if (Directory.Exists(personal))
        {
            foreach (var entry in SafeEnumerateEntries(personal))
            {
                if (!IsPersonalArtefact(Path.GetFileName(entry))) continue;
                total += Directory.Exists(entry)
                    ? SafeEnumerateFiles(entry).Sum(SafeLength)
                    : SafeLength(entry);
            }
        }

        return total;
    }

    /// <summary>Deletes the learning data, reporting what survived.</summary>
    public static EraseResult Erase(string? dataDirectory = null)
    {
        var root = dataDirectory ?? DataDirectory;
        var removed = new List<string>();
        var failed = new List<string>();

        if (!Directory.Exists(root)) return new EraseResult(removed, failed);

        foreach (var path in SafeEnumerateFiles(root))
        {
            if (!IsLearningArtefact(Path.GetFileName(path))) continue;
            Remove(path, removed, failed);
        }

        var personal = Path.Combine(root, "personal");
        if (Directory.Exists(personal))
        {
            foreach (var entry in SafeEnumerateEntries(personal))
            {
                if (!IsPersonalArtefact(Path.GetFileName(entry))) continue;
                Remove(entry, removed, failed);
            }
        }

        return new EraseResult(removed, failed);
    }

    private static void Remove(string path, List<string> removed, List<string> failed)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
            else File.Delete(path);
            removed.Add(path);
        }
        catch (Exception)
        {
            // Almost always the engine holding the file. Recorded rather than
            // thrown: the other files should still go, and the caller needs the
            // whole picture to tell the user what to do about it.
            failed.Add(path);
        }
    }

    private static IEnumerable<string> SafeEnumerateFiles(string directory)
    {
        try { return Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).ToList(); }
        catch (Exception) { return Array.Empty<string>(); }
    }

    private static IEnumerable<string> SafeEnumerateEntries(string directory)
    {
        try { return Directory.EnumerateFileSystemEntries(directory).ToList(); }
        catch (Exception) { return Array.Empty<string>(); }
    }

    private static long SafeLength(string path)
    {
        try { return new FileInfo(path).Length; }
        catch (Exception) { return 0; }
    }
}
