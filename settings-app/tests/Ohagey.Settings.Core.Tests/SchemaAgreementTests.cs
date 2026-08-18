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
        // Read by OhageyTSF.dll rather than by the engine, which makes this the
        // one name here whose other implementation is a C++ string literal in
        // OhageyLog.cpp. It is also listed in SettingsSchema.swift, which
        // nothing in Swift reads: that enum is the registry contract, and a
        // name only the DLL knows is a name someone reuses (decision 0033).
        Assert.Equal("DiagnosticLog", SettingsSchema.DiagnosticLog);
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
        // Both on since the base language model ships (decision 0034). They
        // were deliberately different for a month, while personalisation cost
        // more than it gave; that turned out to be how the personal model was
        // built, not the feature. Pinned either way — this pair drifting apart
        // is invisible until someone notices a setting doing nothing.
        Assert.True(defaults.PersonalizationEnabled);
        Assert.Equal(100, defaults.PersonalizationAlphaPercent);
        Assert.Equal(Backend.Cpu, defaults.Backend);
        Assert.Equal(10, defaults.ZenzaiInferenceLimit);
        Assert.Equal(300, defaults.IdleTimeoutSeconds);
        // Off, and this one is not a preference so much as a promise: the DLL
        // is loaded into every application with a text input surface and opens
        // a file twice per conversion while this is on. Defaulting it to true
        // would put a shipped IME on the disk at every space bar.
        Assert.False(defaults.DiagnosticLog);
    }

    [Fact]
    public void TheDiagnosticLogDoesNotAskForAnEngineRestart()
    {
        // The engine never reads it. What has to restart is each of the user's
        // own applications, which is a different sentence and is said on the
        // About page — listing it here would show the wrong one.
        Assert.DoesNotContain(SettingsSchema.DiagnosticLog, SettingsSchema.RequiringRestart);
    }

    [Fact]
    public void TheDiagnosticLogPathIsWhereTheTextServiceWrites()
    {
        // OhageyLog.cpp builds "%LOCALAPPDATA%\Ohagey\tsf.log" from
        // FOLDERID_LocalAppData. Same directory as the learning data, which is
        // where the engine's own log goes too.
        Assert.Equal(Path.Combine(LearningData.DataDirectory, "tsf.log"), Diagnostics.LogPath);
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

    // ── Decision 0034: the base language model's filenames ──────────────────
    //
    // Written twice, like everything else here — EngineSettings.swift builds
    // the same four paths. A disagreement does not fail anything: the engine
    // decides the model is absent, falls back to an empty base, and
    // personalisation goes inert while the settings app reports it installed.
    // That is the exact failure mode this whole section exists to prevent.

    [Fact]
    public void TheBaseLanguageModelSuffixesAreWhatTheEngineLooksFor()
    {
        // Four for inference, matching EnginePaths.baseLanguageModelSuffixes.
        Assert.Equal(
            new[] { "_c_abc", "_r_xbx", "_u_abx", "_u_xbc" },
            ModelState.BaseLanguageModelSuffixes);
        // The fifth is what a resumed training run needs, and the engine wants
        // it before it will personalise at all
        // (EnginePaths.baseLanguageModelResumeSuffixes).
        Assert.Equal("_c_bc", ModelState.BaseLanguageModelResumeSuffix);
    }

    [Fact]
    public void TheBaseLanguageModelFilenamesAreWhatTheInstallerWrites()
    {
        var names = ModelState.BaseLanguageModelPaths.Select(Path.GetFileName).ToArray();
        Assert.Equal(
            new[] { "lm_c_abc.marisa", "lm_r_xbx.marisa", "lm_u_abx.marisa", "lm_u_xbc.marisa" },
            names);

        // All five, in the order ohagey.iss downloads them under base-lm-v1.
        var resume = ModelState.BaseLanguageModelResumePaths.Select(Path.GetFileName).ToArray();
        Assert.Equal(
            new[]
            {
                "lm_c_abc.marisa", "lm_r_xbx.marisa", "lm_u_abx.marisa", "lm_u_xbc.marisa",
                "lm_c_bc.marisa",
            },
            resume);
    }

    [Fact]
    public void InstalledMeansPersonalisationCanActuallyRun()
    {
        // The fifth file is the whole point of this assertion.
        //
        // The engine applies personalisation only when it can train by
        // *resuming* from the base (isBaseLanguageModelResumable, five files).
        // This class reported "installed" on four until our own base started
        // shipping, so a machine that lost exactly lm_c_bc.marisa — one of five
        // independent downloads, none of which fail the installation — was told
        // the model was there while the engine did nothing at all.
        //
        // Asserting the rule rather than the machine: whatever the real
        // Program Files holds, "installed" has to mean the same thing the
        // engine means by it.
        Assert.Equal(
            ModelState.BaseLanguageModelResumePaths.All(File.Exists),
            ModelState.IsBaseLanguageModelInstalled);
        Assert.Equal(5, ModelState.BaseLanguageModelResumePaths.Count());
    }

    [Fact]
    public void TheBaseLanguageModelSitsBesideTheWeights()
    {
        // Same directory as the gguf, because that is the one the engine
        // derives both from (EnginePaths.modelDirectory).
        foreach (var path in ModelState.BaseLanguageModelResumePaths)
        {
            Assert.Equal(ModelState.ModelDirectory, Path.GetDirectoryName(path));
        }
        Assert.Equal(ModelState.ModelDirectory, Path.GetDirectoryName(ModelState.ModelPath));
    }

    [Fact]
    public void TheBaseModelMessageSaysWhatIsWrongInBothStates()
    {
        var whenOn = ModelState.DescribeBaseLanguageModel(personalizationEnabled: true);
        var whenOff = ModelState.DescribeBaseLanguageModel(personalizationEnabled: false);

        Assert.NotEmpty(whenOn);
        Assert.NotEmpty(whenOff);
        // The two cases have to read differently. Someone who deliberately
        // turned the switch on needs a different sentence from someone who
        // never touched it, and an identical string here would mean the
        // distinction was lost in a refactor.
        Assert.NotEqual(whenOn, whenOff);
    }
}
