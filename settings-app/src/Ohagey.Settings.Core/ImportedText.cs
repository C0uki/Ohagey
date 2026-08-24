// Text the user hands to personalisation deliberately (decision 0037).
//
// ── This is the third implementation of one file format ─────────────────────
//
// The engine reads the same file, in Swift, in
// OhageyEngineCore/Personalization.swift. Same hazard as the settings schema:
// a disagreement is not a build error, it is an import that appears to succeed
// and trains on something else — or a limit this app enforces and the engine
// does not, so the engine silently ignores a file the user was told was fine.
//
// The filename, the limit and the normalisation rules are pinned against the
// Swift side in SchemaAgreementTests.
//
// ── Why the feature exists ──────────────────────────────────────────────────
//
// The personal n-gram is trained on a few thousand characters of committed
// phrases; the base it is subtracted from is trained on over a million.
// azooKey's own Tuner closes that gap by collecting text across applications,
// which decisions 0016 and 0025 rule out here. Being handed a file is the
// version of that which asks first — and it is the user's file, read once, and
// never sent anywhere.

namespace Ohagey.Settings.Core;

/// <summary>Why a file could not be imported.</summary>
public enum ImportRejection
{
    None,
    /// <summary>Nothing in it survived normalisation.</summary>
    Empty,
    /// <summary>Longer than the engine will train on.</summary>
    TooLong,
    /// <summary>Could not be read as UTF-8 text at all.</summary>
    Unreadable,
}

/// <summary>The outcome of examining or importing a file.</summary>
public sealed record ImportResult(
    ImportRejection Rejection,
    int Lines,
    int Characters)
{
    public bool Accepted => Rejection == ImportRejection.None;
}

public static class ImportedText
{
    /// <summary>Where the engine looks for it (decision 0037).</summary>
    /// <remarks>
    /// Beside the corpus and the trained generations, not with them: it is
    /// never trimmed and the erase button does not touch it.
    /// </remarks>
    public static string FilePath => Path.Combine(LearningData.PersonalDirectory, "imported.txt");

    /// <summary>
    /// Most characters the engine will train on.
    /// </summary>
    /// <remarks>
    /// Characters rather than lines, because training cost is per character:
    /// 41µs and 780 bytes of peak memory each, measured across three orders of
    /// magnitude (decision 0034). A line limit would let one pasted book
    /// through.
    ///
    /// Mirrors <c>PersonalizationLayout.importedTextCharacterLimit</c>. This
    /// app enforcing a larger one would produce a file the engine refuses; a
    /// smaller one would refuse files that would have worked.
    /// </remarks>
    public const int CharacterLimit = 100_000;

    /// <summary>Longest single line kept, matching the corpus rule.</summary>
    public const int MaximumLineLength = 200;

    /// <summary>Seconds each retraining run is lengthened by.</summary>
    /// <remarks>
    /// Every run reads the whole file, so an import is not paid once — it is
    /// paid on every retrain for as long as it is there. Shown to the user
    /// before they commit, which is the only reason this constant is
    /// duplicated on this side at all.
    /// </remarks>
    public static double TrainingSecondsAdded(int characters) =>
        Math.Max(0, characters) * 0.000_041;

    /// <summary>
    /// Normalises raw file contents into the lines the engine will train on.
    /// </summary>
    /// <remarks>
    /// Has to match <c>PersonalizationLayout.importedLines</c>, which splits on
    /// <c>Character.isNewline</c> and then drops blanks and over-long lines.
    ///
    /// The separator set is that property's, not just CR and LF: Swift counts
    /// the vertical tab, the form feed, NEL and the two Unicode separators as
    /// newlines too. Splitting on fewer here would join two lines into one the
    /// engine may then drop for length, which reads as text going missing.
    /// CRLF needs no special case -- splitting on both leaves an empty string
    /// between them, and empties are dropped.
    /// </remarks>
    public static IReadOnlyList<string> Normalise(string contents)
    {
        var lines = new List<string>();
        foreach (var raw in contents.Split(Newlines))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.Length > MaximumLineLength) continue;
            lines.Add(line);
        }
        return lines;
    }

    /// <summary>Every character Swift's <c>Character.isNewline</c> accepts.</summary>
    private static readonly char[] Newlines =
    {
        '\n', '\v', '\f', '\r', '\u0085', '\u2028', '\u2029',
    };

    /// <summary>Reads a file and reports whether it could be imported.</summary>
    /// <remarks>
    /// Separate from <see cref="Import"/> so the app can say what will happen
    /// before writing anything. An over-long file is rejected rather than
    /// truncated: keeping the first hundred thousand characters would train on
    /// the front of a document while telling the user the whole thing was
    /// imported, and they would have no way to see which part took effect.
    /// </remarks>
    public static ImportResult Examine(string path)
    {
        string contents;
        try
        {
            contents = File.ReadAllText(path);
        }
        catch (Exception)
        {
            return new ImportResult(ImportRejection.Unreadable, 0, 0);
        }

        var lines = Normalise(contents);
        if (lines.Count == 0) return new ImportResult(ImportRejection.Empty, 0, 0);

        var characters = lines.Sum(line => line.Length);
        return characters > CharacterLimit
            ? new ImportResult(ImportRejection.TooLong, lines.Count, characters)
            : new ImportResult(ImportRejection.None, lines.Count, characters);
    }

    /// <summary>Imports a file, replacing whatever was there.</summary>
    /// <remarks>
    /// Replaces rather than appends. Appending would make "import" an action
    /// with no inverse short of deleting everything, and would let a user
    /// double the training cost by picking the same file twice without
    /// noticing.
    ///
    /// Written normalised rather than verbatim, so what is on disk is what the
    /// engine will train on — a user who opens the file sees the same thing the
    /// IME sees.
    /// </remarks>
    public static ImportResult Import(string path)
    {
        var examined = Examine(path);
        if (!examined.Accepted) return examined;

        var lines = Normalise(File.ReadAllText(path));
        Directory.CreateDirectory(LearningData.PersonalDirectory);
        // LF, and a trailing newline: the engine writes the corpus the same
        // way, and its reader treats "\r\n" as a single Character — a file
        // written with CRLF is read back correctly but needlessly differs from
        // what the engine produces.
        File.WriteAllText(FilePath, string.Join("\n", lines) + "\n");
        return examined;
    }

    public static bool Exists => File.Exists(FilePath);

    /// <summary>What is currently imported, or null when there is nothing.</summary>
    public static ImportResult? Current
    {
        get
        {
            if (!Exists) return null;
            var result = Examine(FilePath);
            return result.Rejection == ImportRejection.Unreadable ? null : result;
        }
    }

    /// <summary>Removes the imported text.</summary>
    /// <remarks>
    /// The engine notices by modification date on the next conversion and
    /// retrains without it, so this genuinely takes the text back out of the
    /// model rather than only out of the file.
    /// </remarks>
    public static bool Delete()
    {
        try
        {
            if (Exists) File.Delete(FilePath);
            return !Exists;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>What to show the user about the current import.</summary>
    public static string Describe()
    {
        var current = Current;
        if (current is null)
        {
            return "取り込んだテキストはありません。"
                 + "よく書く文章を読み込ませると、変換の候補順がその文体に寄ります。";
        }

        if (current.Rejection == ImportRejection.TooLong)
        {
            // Only reachable if the file was edited outside this app. The
            // engine ignores it entirely in this state, so saying "imported"
            // would be false.
            return $"取り込んだテキストが大きすぎます({current.Characters:N0} 文字 / "
                 + $"上限 {CharacterLimit:N0} 文字)。この状態では学習に使われません。";
        }

        var seconds = TrainingSecondsAdded(current.Characters);
        return $"{current.Lines:N0} 行 / {current.Characters:N0} 文字を取り込み済みです。"
             + $"学習のたびに約 {seconds:0.#} 秒ぶん時間が延びます。";
    }

    /// <summary>Why a rejected file was rejected, in the user's terms.</summary>
    public static string Explain(ImportResult result) => result.Rejection switch
    {
        ImportRejection.Empty =>
            "取り込める文章が見つかりませんでした。1行に1文ずつ書かれたテキストファイルを選んでください。",
        ImportRejection.TooLong =>
            $"ファイルが大きすぎます({result.Characters:N0} 文字)。上限は {CharacterLimit:N0} 文字です。"
            + "確定のたびに学習し直すため、大きいほど時間がかかります。分割して取り込んでください。",
        ImportRejection.Unreadable =>
            "ファイルを読み取れませんでした。UTF-8 のテキストファイルを選んでください。",
        _ => string.Empty,
    };
}
