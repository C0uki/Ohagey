// The user dictionary file, as the settings app edits it (decision 0036).
//
// The second implementation of this format; the engine's is in
// engine/Sources/OhageyEngineCore/UserDictionary.swift. See the note at the top
// of SettingsSchema.cs about why two implementations are tolerable here and
// what keeps them together.
//
// The rule that matters most: a line that does not parse costs one word, not
// the file. This holds words someone may have typed in over years, and it is
// plausibly hand-edited.

using System.Text;

namespace Ohagey.Settings.Core;

/// <summary>Part of speech, by the names the file uses.</summary>
/// <remarks>
/// Deliberately a small closed set with ASCII keys. The converter wants numeric
/// ids that mean nothing outside it and are free to change between upstream
/// versions; a user's dictionary file must not depend on those. The mapping
/// lives in the engine, beside the converter.
///
/// These are keys, not labels. Anything shown to a user is a separate,
/// translatable string — see <see cref="PartsOfSpeech.DisplayName"/>.
/// </remarks>
public enum PartOfSpeech
{
    Noun,
    ProperNoun,
    PersonName,
    Surname,
    GivenName,
    Organization,
    PlaceName,
    Symbol,
}

public static class PartsOfSpeech
{
    /// <summary>The fallback for a missing or unrecognised part of speech.</summary>
    /// <remarks>
    /// A file naming one this build has never heard of is a newer settings app,
    /// not a reason to drop the user's word.
    /// </remarks>
    public const PartOfSpeech Fallback = PartOfSpeech.Noun;

    /// <summary>The key as written in the file.</summary>
    public static string ToKey(this PartOfSpeech value) => value switch
    {
        PartOfSpeech.Noun => "noun",
        PartOfSpeech.ProperNoun => "propernoun",
        PartOfSpeech.PersonName => "personname",
        PartOfSpeech.Surname => "surname",
        PartOfSpeech.GivenName => "givenname",
        PartOfSpeech.Organization => "organization",
        PartOfSpeech.PlaceName => "placename",
        PartOfSpeech.Symbol => "symbol",
        _ => "noun",
    };

    public static PartOfSpeech FromKey(string? key) => key?.Trim().ToLowerInvariant() switch
    {
        "noun" => PartOfSpeech.Noun,
        "propernoun" => PartOfSpeech.ProperNoun,
        "personname" => PartOfSpeech.PersonName,
        "surname" => PartOfSpeech.Surname,
        "givenname" => PartOfSpeech.GivenName,
        "organization" => PartOfSpeech.Organization,
        "placename" => PartOfSpeech.PlaceName,
        "symbol" => PartOfSpeech.Symbol,
        _ => Fallback,
    };

    /// <summary>What the UI shows. Japanese, because the users are.</summary>
    public static string DisplayName(this PartOfSpeech value) => value switch
    {
        PartOfSpeech.Noun => "名詞",
        PartOfSpeech.ProperNoun => "固有名詞",
        PartOfSpeech.PersonName => "人名",
        PartOfSpeech.Surname => "人名(姓)",
        PartOfSpeech.GivenName => "人名(名)",
        PartOfSpeech.Organization => "組織名",
        PartOfSpeech.PlaceName => "地名",
        PartOfSpeech.Symbol => "記号",
        _ => "名詞",
    };
}

/// <summary>One registered word.</summary>
public sealed record UserDictionaryEntry(
    string Reading,
    string Word,
    PartOfSpeech PartOfSpeech = PartsOfSpeech.Fallback);

/// <summary>Why an entry was refused.</summary>
public enum UserDictionaryProblem
{
    None,
    EmptyReading,
    EmptyWord,
    ReadingIsNotKana,
    ReadingTooLong,
    WordTooLong,
}

public static class UserDictionary
{
    /// <summary>First line, so a reader can tell what it is looking at.</summary>
    public const string Header = "#!ohagey-userdict 1";

    public const int MaximumFieldLength = 100;
    public const int MaximumEntries = 10_000;

    /// <summary>The file, under the per-user data directory (decision 0024).</summary>
    public static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Ohagey",
        "userdict.tsv");

    // ── Validation ──────────────────────────────────────────────────────────

    /// <summary>Checks an entry, returning <see cref="UserDictionaryProblem.None"/> when it is fine.</summary>
    public static UserDictionaryProblem Validate(UserDictionaryEntry entry)
    {
        var reading = entry.Reading.Trim();
        var word = entry.Word.Trim();

        if (reading.Length == 0) return UserDictionaryProblem.EmptyReading;
        if (word.Length == 0) return UserDictionaryProblem.EmptyWord;
        if (reading.Length > MaximumFieldLength) return UserDictionaryProblem.ReadingTooLong;
        if (word.Length > MaximumFieldLength) return UserDictionaryProblem.WordTooLong;
        if (!IsKana(reading)) return UserDictionaryProblem.ReadingIsNotKana;
        return UserDictionaryProblem.None;
    }

    /// <summary>What to tell the user about a refused entry.</summary>
    public static string Describe(UserDictionaryProblem problem) => problem switch
    {
        UserDictionaryProblem.EmptyReading => "読みを入力してください。",
        UserDictionaryProblem.EmptyWord => "単語を入力してください。",
        // Said this way on purpose: typing the word into the reading field is
        // the usual cause, and an entry with a kanji reading would be stored
        // successfully and then never convert.
        UserDictionaryProblem.ReadingIsNotKana =>
            "読みはひらがな・カタカナで入力してください(単語を読みの欄に入れていませんか?)。",
        UserDictionaryProblem.ReadingTooLong => $"読みが長すぎます({MaximumFieldLength}文字まで)。",
        UserDictionaryProblem.WordTooLong => $"単語が長すぎます({MaximumFieldLength}文字まで)。",
        _ => string.Empty,
    };

    /// <summary>Hiragana, katakana, the長音 mark and the kana middle dot.</summary>
    /// <remarks>
    /// The converter looks entries up by their kana reading, so anything
    /// outside this cannot be reached by typing no matter what was meant.
    /// </remarks>
    public static bool IsKana(string text)
    {
        if (text.Length == 0) return false;
        foreach (var c in text)
        {
            var ok = c is >= 'ぁ' and <= 'ゖ'      // hiragana
                or >= 'ァ' and <= 'ヺ'             // katakana
                or 'ー'                                // ー
                or '・';                               // ・
            if (!ok) return false;
        }
        return true;
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    /// <summary>Entries read from the file's contents, and the lines that could not be read.</summary>
    /// <remarks>
    /// Never throws and never gives up on the file. Losing one hand-edited line
    /// should not cost someone every word they ever registered.
    /// </remarks>
    public static (List<UserDictionaryEntry> Entries, List<int> SkippedLines) Parse(string contents)
    {
        var entries = new List<UserDictionaryEntry>();
        var skipped = new List<int>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        var lines = contents.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i].TrimEnd('\r').Trim();
            // Blank lines and comments — the version header is one of these.
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var fields = line.Split('\t');
            if (fields.Length < 2)
            {
                skipped.Add(i + 1);
                continue;
            }

            var entry = new UserDictionaryEntry(
                fields[0].Trim(),
                fields[1].Trim(),
                // Extra fields are a later format this build does not
                // understand; reading the ones it knows beats refusing the line.
                fields.Length > 2 ? PartsOfSpeech.FromKey(fields[2]) : PartsOfSpeech.Fallback);

            if (Validate(entry) != UserDictionaryProblem.None)
            {
                skipped.Add(i + 1);
                continue;
            }

            // Keyed by reading *and* word: one reading with several words is
            // exactly what a user dictionary is for, so only an exact repeat
            // is a duplicate.
            if (!seen.Add($"{entry.Reading}\t{entry.Word}")) continue;

            entries.Add(entry);
            if (entries.Count >= MaximumEntries) break;
        }

        return (entries, skipped);
    }

    // ── Writing ─────────────────────────────────────────────────────────────

    /// <summary>Renders entries as the file's contents.</summary>
    public static string Serialize(IEnumerable<UserDictionaryEntry> entries)
    {
        var builder = new StringBuilder();
        builder.Append(Header).Append('\n');
        foreach (var entry in entries)
        {
            builder
                .Append(Sanitize(entry.Reading)).Append('\t')
                .Append(Sanitize(entry.Word)).Append('\t')
                .Append(entry.PartOfSpeech.ToKey()).Append('\n');
        }
        return builder.ToString();
    }

    /// <summary>
    /// Replaces the characters that would make the file read back as something
    /// else.
    /// </summary>
    /// <remarks>
    /// Replaced rather than escaped: an escaping scheme is one more thing a
    /// hand-editor has to know, and neither a tab nor a newline belongs in a
    /// reading or a word.
    /// </remarks>
    public static string Sanitize(string field) => field
        .Replace('\t', ' ')
        .Replace('\r', ' ')
        .Replace('\n', ' ')
        .Trim();
}

/// <summary>Reads and writes the dictionary file.</summary>
public interface IUserDictionaryStore
{
    (List<UserDictionaryEntry> Entries, List<int> SkippedLines) Read();
    void Write(IEnumerable<UserDictionaryEntry> entries);
}

public sealed class FileUserDictionaryStore : IUserDictionaryStore
{
    private readonly string _path;

    public FileUserDictionaryStore(string? path = null) => _path = path ?? UserDictionary.FilePath;

    public (List<UserDictionaryEntry> Entries, List<int> SkippedLines) Read()
    {
        if (!File.Exists(_path)) return (new List<UserDictionaryEntry>(), new List<int>());
        return UserDictionary.Parse(File.ReadAllText(_path, Encoding.UTF8));
    }

    /// <summary>Writes the file, replacing it atomically.</summary>
    /// <remarks>
    /// The engine re-reads this whenever its timestamp changes (decision 0036),
    /// so it can read at any moment. A partial write would parse — as a
    /// dictionary with the user's later words missing, which looks exactly like
    /// having lost them.
    /// </remarks>
    public void Write(IEnumerable<UserDictionaryEntry> entries)
    {
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        var temporary = _path + ".tmp";
        // No BOM: the engine reads this as plain UTF-8 and a BOM would land in
        // the first line, which is the version header.
        File.WriteAllText(temporary, UserDictionary.Serialize(entries), new UTF8Encoding(false));

        if (File.Exists(_path)) File.Replace(temporary, _path, destinationBackupFileName: null);
        else File.Move(temporary, _path);
    }
}
