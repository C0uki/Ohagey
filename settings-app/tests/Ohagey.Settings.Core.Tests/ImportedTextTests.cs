// Importing text for personalisation to train on (decision 0037).
//
// The normalisation is the part worth testing: it is implemented twice, and
// the two implementations have to agree line for line. If this app writes a
// file the engine normalises differently, the user is shown a character count
// that is not what will be trained on — and nothing anywhere fails.

using Ohagey.Settings.Core;
using Xunit;

namespace Ohagey.Settings.Core.Tests;

public class ImportedTextTests
{
    [Fact]
    public void BlankAndOverLongLinesAreDropped()
    {
        // Same rule as the corpus: the training input is line-based, and a line
        // the length of a pasted chapter would skew the model out of
        // proportion to everything around it.
        var tooLong = new string('あ', ImportedText.MaximumLineLength + 1);
        var lines = ImportedText.Normalise($"今日はいい天気です\n\n   \n{tooLong}\n飛行機に間に合った\n");

        Assert.Equal(new[] { "今日はいい天気です", "飛行機に間に合った" }, lines);
    }

    [Fact]
    public void CrlfDoesNotProduceEmptyOrDoubledLines()
    {
        // Splitting on CR and LF leaves an empty string between them, which the
        // blank-line rule then drops. Worth pinning because the Swift side
        // reaches the same result by a completely different route — there,
        // "\r\n" is a single Character.
        var lines = ImportedText.Normalise("一行目\r\n二行目\r\n");
        Assert.Equal(new[] { "一行目", "二行目" }, lines);
    }

    [Fact]
    public void TheUnicodeLineSeparatorsCountAsNewlines()
    {
        // Swift's Character.isNewline accepts NEL and the two Unicode
        // separators, so the engine splits on them. Splitting on fewer here
        // would join two lines into one, and the count shown to the user would
        // not be what gets trained.
        var lines = ImportedText.Normalise(
            "一行目" + "\u0085" + "二行目" + "\u2028" + "三行目" + "\u2029" + "四行目");
        Assert.Equal(new[] { "一行目", "二行目", "三行目", "四行目" }, lines);
    }

    [Fact]
    public void AFileWithNothingUsableIsRejectedRatherThanImportedAsEmpty()
    {
        var path = WriteTemp("\n   \n\r\n");
        try
        {
            var result = ImportedText.Examine(path);
            Assert.Equal(ImportRejection.Empty, result.Rejection);
            Assert.False(result.Accepted);
            Assert.NotEmpty(ImportedText.Explain(result));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void AFileThatIsNotThereIsUnreadableRatherThanEmpty()
    {
        // The two send the user to different places: one means "pick a
        // different file", the other means "that file did not open".
        var result = ImportedText.Examine(Path.Combine(Path.GetTempPath(), "ohagey-no-such-file.txt"));
        Assert.Equal(ImportRejection.Unreadable, result.Rejection);
    }

    [Fact]
    public void AnOverLongFileIsRejectedAndSaysBySoMuch()
    {
        // Rejected, not truncated. Keeping the first hundred thousand
        // characters would train on the front of a document while reporting
        // the whole thing imported.
        var line = new string('あ', 100) + "\n";
        var contents = string.Concat(Enumerable.Repeat(line, (ImportedText.CharacterLimit / 100) + 5));
        var path = WriteTemp(contents);
        try
        {
            var result = ImportedText.Examine(path);
            Assert.Equal(ImportRejection.TooLong, result.Rejection);
            Assert.True(result.Characters > ImportedText.CharacterLimit);
            // The count is in the message, because "too big" without a number
            // gives the user nothing to act on.
            Assert.Contains(result.Characters.ToString("N0"), ImportedText.Explain(result));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void TheBoundaryIsInclusiveOnBothSides()
    {
        // Exactly the limit is accepted and one more is not. Off by one here
        // means this app accepts a file the engine drops entirely, or refuses
        // one that would have worked -- and neither shows up as an error.
        var atLimit = WriteLines(ImportedText.CharacterLimit);
        var overLimit = WriteLines(ImportedText.CharacterLimit + 1);
        try
        {
            var ok = ImportedText.Examine(atLimit);
            Assert.True(ok.Accepted);
            Assert.Equal(ImportedText.CharacterLimit, ok.Characters);

            var over = ImportedText.Examine(overLimit);
            Assert.Equal(ImportRejection.TooLong, over.Rejection);
            Assert.Equal(ImportedText.CharacterLimit + 1, over.Characters);
        }
        finally
        {
            File.Delete(atLimit);
            File.Delete(overLimit);
        }
    }

    /// <summary>Writes a file whose normalised length is exactly this many characters.</summary>
    private static string WriteLines(int characters)
    {
        var lines = new List<string>();
        var remaining = characters;
        while (remaining > 0)
        {
            var take = Math.Min(remaining, ImportedText.MaximumLineLength);
            lines.Add(new string('あ', take));
            remaining -= take;
        }
        return WriteTemp(string.Join("\n", lines) + "\n");
    }

    [Fact]
    public void TheAddedTrainingTimeIsTheMeasuredRate()
    {
        // 41µs per character (decision 0034). Duplicated from the Swift side
        // only so the user can be told the cost before they commit, which makes
        // a wrong constant here a wrong promise rather than a wrong model.
        Assert.Equal(41.0, ImportedText.TrainingSecondsAdded(1_000_000), 3);
        Assert.Equal(4.1, ImportedText.TrainingSecondsAdded(ImportedText.CharacterLimit), 3);
        Assert.Equal(0, ImportedText.TrainingSecondsAdded(-5));
    }

    [Fact]
    public void ImportedTextIsNotLearningDataAndSurvivesErasing()
    {
        // The distinction decision 0037 turns on. The corpus is a record of
        // what was typed and the erase button takes it; imported text is
        // something the user handed over on purpose, like a dictionary entry,
        // and taking it would throw away work they did deliberately.
        Assert.False(LearningData.IsPersonalArtefact("imported.txt"));
        Assert.True(LearningData.IsPersonalArtefact("corpus.txt"));
        Assert.True(LearningData.IsPersonalArtefact("gen-3"));
    }

    [Fact]
    public void TheFileSitsWithTheOtherPersonalisationData()
    {
        // Same directory as the corpus and the generations, different rules.
        Assert.Equal(
            LearningData.PersonalDirectory,
            Path.GetDirectoryName(ImportedText.FilePath));
        Assert.Equal("imported.txt", Path.GetFileName(ImportedText.FilePath));
    }

    [Fact]
    public void TheLimitMatchesTheEnginesOwn()
    {
        // PersonalizationLayout.importedTextCharacterLimit. Enforcing a larger
        // one here would write a file the engine refuses outright; a smaller
        // one would reject files that would have worked.
        Assert.Equal(100_000, ImportedText.CharacterLimit);
        // PersonalizationLayout.maximumLineLength, shared with the corpus.
        Assert.Equal(200, ImportedText.MaximumLineLength);
    }

    private static string WriteTemp(string contents)
    {
        var path = Path.Combine(Path.GetTempPath(), $"ohagey-import-{Guid.NewGuid():N}.txt");
        File.WriteAllText(path, contents);
        return path;
    }
}
