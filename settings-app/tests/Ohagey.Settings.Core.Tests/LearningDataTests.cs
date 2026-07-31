// Erasing learning data (decisions 0025 / 0034).
//
// The tests worth having here are the ones about what is *not* deleted. Erase
// is not undoable, and the difference between "what the IME learned" and "what
// the user typed in on purpose" is the whole of it.

using Ohagey.Settings.Core;
using Xunit;

namespace Ohagey.Settings.Core.Tests;

public class LearningDataTests
{
    [Theory]
    [InlineData("memory.louds")]
    [InlineData("memory.loudschars2")]
    [InlineData("memory.loudstxt3")]
    [InlineData("MEMORY.LOUDS")]
    public void TheConvertersLearningStoreIsLearningData(string name)
    {
        Assert.True(LearningData.IsLearningArtefact(name));
    }

    [Theory]
    [InlineData("userdict.tsv")]
    [InlineData("settings.json")]
    [InlineData("memories.txt")]
    public void OtherFilesAreNot(string name)
    {
        Assert.False(LearningData.IsLearningArtefact(name));
    }

    [Theory]
    [InlineData("corpus.txt")]
    [InlineData("gen-3")]
    [InlineData("gen-12.partial")]
    public void ThePersonalCorpusAndItsModelsAreLearningData(string name)
    {
        Assert.True(LearningData.IsPersonalArtefact(name));
    }

    [Theory]
    [InlineData("base_c_abc.marisa")]
    [InlineData("base_u_abx.marisa")]
    public void TheEmptyBaseModelIsNot(string name)
    {
        // Derived from nothing and containing nothing about anyone. Keeping it
        // saves rebuilding it on the next start (decision 0034).
        Assert.False(LearningData.IsPersonalArtefact(name));
    }

    [Fact]
    public void ErasingRemovesTheLearningDataAndLeavesTheRest()
    {
        using var directory = new TemporaryDirectory();
        var personal = Path.Combine(directory.Path, "personal");
        Directory.CreateDirectory(Path.Combine(personal, "gen-2"));

        File.WriteAllText(Path.Combine(directory.Path, "memory.louds"), "learned");
        File.WriteAllText(Path.Combine(directory.Path, "userdict.tsv"), "registered on purpose");
        File.WriteAllText(Path.Combine(personal, "corpus.txt"), "typed");
        File.WriteAllText(Path.Combine(personal, "base_c_abc.marisa"), "empty base");
        File.WriteAllText(Path.Combine(personal, "gen-2", "model_c_abc.marisa"), "trained");

        var result = LearningData.Erase(directory.Path);

        Assert.True(result.Complete);
        Assert.False(File.Exists(Path.Combine(directory.Path, "memory.louds")));
        Assert.False(File.Exists(Path.Combine(personal, "corpus.txt")));
        Assert.False(Directory.Exists(Path.Combine(personal, "gen-2")));

        // The two that must survive, and the reason this test exists.
        Assert.True(
            File.Exists(Path.Combine(directory.Path, "userdict.tsv")),
            "words registered deliberately are not learning data (decision 0026)");
        Assert.True(
            File.Exists(Path.Combine(personal, "base_c_abc.marisa")),
            "the empty base model contains nothing about the user (decision 0034)");
    }

    [Fact]
    public void ErasingNothingIsNotAnError()
    {
        using var directory = new TemporaryDirectory();

        var result = LearningData.Erase(directory.Path);

        Assert.True(result.Complete);
        Assert.Empty(result.Removed);
    }

    [Fact]
    public void ErasingADirectoryThatIsNotThereIsNotAnError()
    {
        var result = LearningData.Erase(Path.Combine(Path.GetTempPath(), "ohagey-does-not-exist-" + Guid.NewGuid()));

        Assert.True(result.Complete);
        Assert.Empty(result.Removed);
    }

    [Fact]
    public void AFileTheEngineIsHoldingIsReportedRatherThanThrown()
    {
        using var directory = new TemporaryDirectory();
        var held = Path.Combine(directory.Path, "memory.louds");
        File.WriteAllText(held, "learned");
        File.WriteAllText(Path.Combine(directory.Path, "memory.loudschars2"), "also learned");

        // What a running engine looks like from here: the file is open without
        // FILE_SHARE_DELETE, so the delete fails.
        using (var _ = new FileStream(held, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var result = LearningData.Erase(directory.Path);

            Assert.False(result.Complete);
            Assert.Contains(held, result.Failed);
            // The rest still goes: one locked file must not stop the erase.
            Assert.False(File.Exists(Path.Combine(directory.Path, "memory.loudschars2")));
        }
    }

    [Fact]
    public void TheEstimateCountsOnlyWhatWouldBeErased()
    {
        using var directory = new TemporaryDirectory();
        var personal = Path.Combine(directory.Path, "personal");
        Directory.CreateDirectory(personal);

        File.WriteAllText(Path.Combine(directory.Path, "memory.louds"), new string('x', 100));
        File.WriteAllText(Path.Combine(personal, "corpus.txt"), new string('x', 50));
        // Neither of these counts towards what the button will remove.
        File.WriteAllText(Path.Combine(directory.Path, "userdict.tsv"), new string('x', 999));
        File.WriteAllText(Path.Combine(personal, "base_c_abc.marisa"), new string('x', 999));

        Assert.Equal(150, LearningData.EstimateBytes(directory.Path));
    }
}
