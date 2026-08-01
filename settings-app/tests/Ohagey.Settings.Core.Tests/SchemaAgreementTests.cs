// Pins this app's half of the schema against the decisions (0035 / 0036).
//
// These are the tests that matter most in this project, and they look the
// least interesting: they assert constants.
//
// The reason is that the schema is implemented twice — here in C#, and in
// Swift in engine/Sources/OhageyEngineCore/. A mismatch between the two is not
// a build error and not a crash. It is a setting the user changes that
// silently does nothing, or a registered word that never converts. Nothing
// fails; it just quietly does not work.
//
// So the names, the types and the ranges are asserted literally, against what
// the decision documents say rather than against the other implementation's
// source. Changing one side then fails here instead of shipping.

using Ohagey.Settings.Core;
using Xunit;

namespace Ohagey.Settings.Core.Tests;

public class SchemaAgreementTests
{
    // ── Decision 0035: the settings key ─────────────────────────────────────

    [Fact]
    public void TheRegistryPathIsWhatTheEngineReads()
    {
        Assert.Equal(@"Software\Ohagey", SettingsSchema.RegistryPath);
    }

    [Fact]
    public void TheValueNamesAreWhatTheEngineReads()
    {
        Assert.Equal("SchemaVersion", SettingsSchema.SchemaVersion);
        Assert.Equal("LearningEnabled", SettingsSchema.LearningEnabled);
        Assert.Equal("PersonalizationEnabled", SettingsSchema.PersonalizationEnabled);
        Assert.Equal("PersonalizationAlphaPercent", SettingsSchema.PersonalizationAlphaPercent);
        Assert.Equal("Backend", SettingsSchema.Backend);
        Assert.Equal("ZenzaiInferenceLimit", SettingsSchema.ZenzaiInferenceLimit);
        Assert.Equal("IdleTimeoutSeconds", SettingsSchema.IdleTimeoutSeconds);
    }

    [Fact]
    public void TheRangesAreWhatTheEngineClampsTo()
    {
        Assert.Equal(1, SettingsSchema.MinimumInferenceLimit);
        Assert.Equal(100, SettingsSchema.MaximumInferenceLimit);
        Assert.Equal(0, SettingsSchema.MinimumAlphaPercent);
        Assert.Equal(150, SettingsSchema.MaximumAlphaPercent);
        Assert.Equal(0, SettingsSchema.MinimumIdleTimeoutSeconds);
        Assert.Equal(86_400, SettingsSchema.MaximumIdleTimeoutSeconds);
    }

    [Fact]
    public void TheBackendNamesAreWhatTheEngineParses()
    {
        // The engine lowercases before matching, so these are the strings that
        // have to survive the round trip.
        Assert.Equal("cpu", Backend.Cpu.ToString().ToLowerInvariant());
        Assert.Equal("cuda", Backend.Cuda.ToString().ToLowerInvariant());
        Assert.Equal("vulkan", Backend.Vulkan.ToString().ToLowerInvariant());
    }

    [Fact]
    public void TheDefaultsMatchTheEnginesOwn()
    {
        // Not cosmetic: the engine keeps its default for any value this app has
        // not written, so a disagreement here means the app shows one thing and
        // the engine does another until every value has been touched once.
        var defaults = EngineSettings.Default;
        Assert.True(defaults.LearningEnabled);
        Assert.True(defaults.PersonalizationEnabled);
        Assert.Equal(100, defaults.PersonalizationAlphaPercent);
        Assert.Equal(Backend.Cpu, defaults.Backend);
        Assert.Equal(10, defaults.ZenzaiInferenceLimit);
        Assert.Equal(300, defaults.IdleTimeoutSeconds);
    }

    [Fact]
    public void AlphaIsPercentAndNotAFraction()
    {
        // The engine's model holds 1.0. Writing 1 here instead of 100 would be
        // a silent hundredfold error that no type would catch, so the default
        // is asserted in the unit the registry actually stores.
        Assert.Equal(100, EngineSettings.Default.PersonalizationAlphaPercent);
        Assert.InRange(
            EngineSettings.Default.PersonalizationAlphaPercent,
            SettingsSchema.MinimumAlphaPercent,
            SettingsSchema.MaximumAlphaPercent);
    }

    // ── Decision 0036: the user dictionary file ─────────────────────────────

    [Fact]
    public void TheHeaderIsWhatTheEngineWrites()
    {
        Assert.Equal("#!ohagey-userdict 1", UserDictionary.Header);
    }

    [Fact]
    public void ThePartOfSpeechKeysAreWhatTheEngineMaps()
    {
        Assert.Equal("noun", PartOfSpeech.Noun.ToKey());
        Assert.Equal("propernoun", PartOfSpeech.ProperNoun.ToKey());
        Assert.Equal("personname", PartOfSpeech.PersonName.ToKey());
        Assert.Equal("surname", PartOfSpeech.Surname.ToKey());
        Assert.Equal("givenname", PartOfSpeech.GivenName.ToKey());
        Assert.Equal("organization", PartOfSpeech.Organization.ToKey());
        Assert.Equal("placename", PartOfSpeech.PlaceName.ToKey());
        Assert.Equal("symbol", PartOfSpeech.Symbol.ToKey());
    }

    [Fact]
    public void EveryPartOfSpeechHasAKeyAndSurvivesARoundTrip()
    {
        foreach (PartOfSpeech value in Enum.GetValues<PartOfSpeech>())
        {
            var key = value.ToKey();
            Assert.NotEmpty(key);
            Assert.All(key, c => Assert.True(char.IsAsciiLetterLower(c), $"{key} should be lowercase ASCII"));
            Assert.Equal(value, PartsOfSpeech.FromKey(key));
        }
    }

    [Fact]
    public void EveryPartOfSpeechHasSomethingToShowAUser()
    {
        // The key is not a label. A dropdown reading "propernoun" would be a
        // bug even though nothing would break.
        foreach (PartOfSpeech value in Enum.GetValues<PartOfSpeech>())
        {
            Assert.NotEmpty(value.DisplayName());
            Assert.NotEqual(value.ToKey(), value.DisplayName());
        }
    }

    [Fact]
    public void TheFieldAndEntryLimitsMatchTheEngines()
    {
        Assert.Equal(100, UserDictionary.MaximumFieldLength);
        Assert.Equal(10_000, UserDictionary.MaximumEntries);
    }
}
