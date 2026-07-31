// The user dictionary as the settings app handles it (decision 0036).
//
// The same behaviour the engine's tests pin, checked from the writing side.
// The rule under all of it: a line that does not parse costs one word, never
// the file — this holds words someone may have typed in over years.

using System.Text;
using Ohagey.Settings.Core;
using Xunit;

namespace Ohagey.Settings.Core.Tests;

public class UserDictionaryTests
{
    // ── Validation ──────────────────────────────────────────────────────────

    [Fact]
    public void AcceptsAnOrdinaryEntry()
    {
        var entry = new UserDictionaryEntry("おはぎー", "Ohagey", PartOfSpeech.ProperNoun);
        Assert.Equal(UserDictionaryProblem.None, UserDictionary.Validate(entry));
    }

    [Theory]
    [InlineData("御萩")]
    [InlineData("ohagey")]
    [InlineData("お萩ー")]
    [InlineData("123")]
    public void RefusesAReadingThatIsNotKana(string reading)
    {
        // The common mistake: typing the word into the reading field. Lookup is
        // by kana, so such an entry would be stored happily and never match.
        Assert.Equal(
            UserDictionaryProblem.ReadingIsNotKana,
            UserDictionary.Validate(new UserDictionaryEntry(reading, "語")));
    }

    [Theory]
    [InlineData("ひらがな")]
    [InlineData("カタカナ")]
    [InlineData("らーめん")]
    [InlineData("ラーメン")]
    [InlineData("ぁぃぅぇぉ")]
    [InlineData("ヴ")]
    [InlineData("ア・イ")]
    public void AcceptsEveryFormOfKanaAReadingCanContain(string reading)
    {
        Assert.Equal(
            UserDictionaryProblem.None,
            UserDictionary.Validate(new UserDictionaryEntry(reading, "語")));
    }

    [Fact]
    public void RefusesEmptyFields()
    {
        Assert.Equal(
            UserDictionaryProblem.EmptyReading,
            UserDictionary.Validate(new UserDictionaryEntry("  ", "語")));
        Assert.Equal(
            UserDictionaryProblem.EmptyWord,
            UserDictionary.Validate(new UserDictionaryEntry("よみ", "  ")));
    }

    [Fact]
    public void EveryProblemHasSomethingToTellTheUser()
    {
        foreach (UserDictionaryProblem problem in Enum.GetValues<UserDictionaryProblem>())
        {
            if (problem == UserDictionaryProblem.None) continue;
            Assert.NotEmpty(UserDictionary.Describe(problem));
        }
    }

    // ── Parsing ─────────────────────────────────────────────────────────────

    [Fact]
    public void ParsesEntries()
    {
        var (entries, skipped) = UserDictionary.Parse(
            $"{UserDictionary.Header}\nおはぎー\tOhagey\tpropernoun\nたなか\t田中\tsurname\n");

        Assert.Empty(skipped);
        Assert.Equal(
            new[]
            {
                new UserDictionaryEntry("おはぎー", "Ohagey", PartOfSpeech.ProperNoun),
                new UserDictionaryEntry("たなか", "田中", PartOfSpeech.Surname),
            },
            entries);
    }

    [Fact]
    public void ABadLineCostsOneWordAndNoMore()
    {
        var (entries, skipped) = UserDictionary.Parse(
            $"{UserDictionary.Header}\nよみいち\t語一\nthis line has no tab\n御萩\t語二\nよみさん\t語三\n");

        Assert.Equal(new[] { "語一", "語三" }, entries.Select(e => e.Word));
        Assert.Equal(new[] { 3, 4 }, skipped);
    }

    [Fact]
    public void AnUnknownPartOfSpeechFallsBackAndKeepsTheWord()
    {
        var (entries, skipped) = UserDictionary.Parse("よみ\t語\tinterjection\n");

        Assert.Empty(skipped);
        Assert.Equal(PartsOfSpeech.Fallback, entries.Single().PartOfSpeech);
    }

    [Fact]
    public void ExtraFieldsAreIgnoredRatherThanFatal()
    {
        var (entries, skipped) = UserDictionary.Parse("よみ\t語\tnoun\tsomething\telse\n");

        Assert.Empty(skipped);
        Assert.Equal("語", entries.Single().Word);
    }

    [Fact]
    public void HandlesWindowsLineEndings()
    {
        var (entries, skipped) = UserDictionary.Parse(
            $"{UserDictionary.Header}\r\nよみ\t語\r\nよみに\t語二\r\n");

        Assert.Empty(skipped);
        Assert.Equal(2, entries.Count);
    }

    [Fact]
    public void DuplicatesAreCollapsedButOneReadingMayHaveSeveralWords()
    {
        Assert.Single(UserDictionary.Parse("よみ\t語\nよみ\t語\n").Entries);
        Assert.Equal(2, UserDictionary.Parse("よみ\t語一\nよみ\t語二\n").Entries.Count);
    }

    // ── Writing ─────────────────────────────────────────────────────────────

    [Fact]
    public void SerializedOutputParsesBack()
    {
        var original = new[]
        {
            new UserDictionaryEntry("おはぎー", "Ohagey", PartOfSpeech.ProperNoun),
            new UserDictionaryEntry("たなか", "田中", PartOfSpeech.Surname),
        };

        var (parsed, skipped) = UserDictionary.Parse(UserDictionary.Serialize(original));

        Assert.Empty(skipped);
        Assert.Equal(original, parsed);
    }

    [Fact]
    public void TabsAndNewlinesInAFieldCannotCorruptTheFile()
    {
        var awkward = new[] { new UserDictionaryEntry("よみ", "語\t二\n三") };

        var (parsed, skipped) = UserDictionary.Parse(UserDictionary.Serialize(awkward));

        Assert.Empty(skipped);
        Assert.Equal("語 二 三", parsed.Single().Word);
    }

    // ── The file ────────────────────────────────────────────────────────────

    [Fact]
    public void WritesAndReadsBackThroughTheFile()
    {
        using var directory = new TemporaryDirectory();
        var store = new FileUserDictionaryStore(Path.Combine(directory.Path, "userdict.tsv"));
        var entries = new[] { new UserDictionaryEntry("おはぎー", "Ohagey", PartOfSpeech.ProperNoun) };

        store.Write(entries);

        Assert.Equal(entries, store.Read().Entries);
    }

    [Fact]
    public void AMissingFileReadsAsEmptyRatherThanThrowing()
    {
        using var directory = new TemporaryDirectory();
        var store = new FileUserDictionaryStore(Path.Combine(directory.Path, "nothing-here.tsv"));

        Assert.Empty(store.Read().Entries);
    }

    [Fact]
    public void WritingReplacesRatherThanAppending()
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "userdict.tsv");
        var store = new FileUserDictionaryStore(path);

        store.Write(new[] { new UserDictionaryEntry("いち", "一") });
        store.Write(new[] { new UserDictionaryEntry("に", "二") });

        Assert.Equal(new[] { "二" }, store.Read().Entries.Select(e => e.Word));
        Assert.False(File.Exists(path + ".tmp"), "the staging file should not be left behind");
    }

    [Fact]
    public void TheFileHasNoByteOrderMark()
    {
        // A BOM would land at the start of the version header, and the engine
        // reads this as plain UTF-8.
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "userdict.tsv");
        new FileUserDictionaryStore(path).Write(new[] { new UserDictionaryEntry("よみ", "語") });

        var bytes = File.ReadAllBytes(path);
        Assert.False(bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF);
        Assert.StartsWith(UserDictionary.Header, File.ReadAllText(path, Encoding.UTF8));
    }
}

internal sealed class TemporaryDirectory : IDisposable
{
    public string Path { get; }

    public TemporaryDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ohagey-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (Exception) { }
    }
}
