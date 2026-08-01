// Reading the engine's backend status file (decision 0028).
//
// The failure this guards against is specific: the settings app telling a user
// their GPU is in use when it is not. That is worse than saying nothing,
// because it sends them looking for the slowness somewhere else.
//
// The engine's half is engine/Sources/OhageyEngineCore/BackendStatus.swift, and
// has the mirror of these tests in engine/Tests/.../BackendTests.swift. The
// literal file contents below are the contract between them.

using Ohagey.Settings.Core;
using Xunit;

namespace Ohagey.Settings.Core.Tests;

public class BackendStatusParsingTests
{
    // Exactly what the engine writes for the ordinary case, copied from
    // BackendStatusFile.serialize. If the engine's format changes, this fails
    // here rather than showing a blank status on a user's machine.
    private const string EngineOutput =
        "version\t1\n"
        + "requested\tcuda\n"
        + "effective\tcuda\n"
        + "reason\trequested\n"
        + "recorded-at\t2025-07-31T22:13:20Z\n";

    [Fact]
    public void ReadsWhatTheEngineWrites()
    {
        var status = BackendStatusFile.Parse(EngineOutput);

        Assert.NotNull(status);
        Assert.Equal(Backend.Cuda, status.Requested);
        Assert.Equal(Backend.Cuda, status.Effective);
        Assert.Equal(BackendSelectionReason.Requested, status.Reason);
        Assert.True(status.IsHonoringRequest);
        Assert.Equal(
            new DateTimeOffset(2025, 7, 31, 22, 13, 20, TimeSpan.Zero),
            status.RecordedAt);
    }

    [Fact]
    public void ReadsAFallbackAsAFallback()
    {
        var status = BackendStatusFile.Parse(
            "version\t1\nrequested\tcuda\neffective\tcpu\nreason\tload-failed\ndetail\t126\n");

        Assert.NotNull(status);
        Assert.Equal(Backend.Cuda, status.Requested);
        Assert.Equal(Backend.Cpu, status.Effective);
        Assert.Equal(BackendSelectionReason.LoadFailed, status.Reason);
        Assert.Equal("126", status.Detail);
        Assert.False(status.IsHonoringRequest);
    }

    [Fact]
    public void AnAbsentEffectiveBackendMeansNothingLoaded()
    {
        var status = BackendStatusFile.Parse("requested\tvulkan\nreason\tunavailable\n");

        Assert.NotNull(status);
        Assert.Null(status.Effective);
    }

    [Fact]
    public void IgnoresKeysWrittenByANewerEngine()
    {
        // Degrading to less rather than to nothing. The engine is upgraded by
        // the same installer as this app, but they are separate files and an
        // interrupted upgrade can leave them out of step.
        var status = BackendStatusFile.Parse(
            "requested\tcpu\nreason\trequested\nfuture-field\tsomething\n");

        Assert.NotNull(status);
        Assert.Equal(Backend.Cpu, status.Requested);
    }

    [Theory]
    [InlineData("")]
    [InlineData("version\t1\n")]
    [InlineData("requested\tcuda\n")]              // no reason
    [InlineData("reason\trequested\n")]            // no requested backend
    [InlineData("requested\tmetal\nreason\trequested\n")]
    [InlineData("requested\tcpu\nreason\twhoops\n")]
    public void RejectsAFileThatCannotBeTrusted(string text)
    {
        // A truncated or unrecognised file must not read as a default, because
        // the default would say everything is fine.
        Assert.Null(BackendStatusFile.Parse(text));
    }

    [Fact]
    public void AnUnreadableEffectiveBackendIsNotTreatedAsWorking()
    {
        var status = BackendStatusFile.Parse(
            "requested\tcuda\neffective\tmetal\nreason\trequested\n");

        Assert.NotNull(status);
        Assert.Null(status.Effective);
    }

    [Fact]
    public void ARunOfTheMillCrlfFileStillParses()
    {
        // The engine writes \n, but the file is meant to be openable in Notepad
        // while diagnosing somebody's machine — and saved again from it.
        var status = BackendStatusFile.Parse("requested\tcpu\r\nreason\trequested\r\n");

        Assert.NotNull(status);
        Assert.Equal(BackendSelectionReason.Requested, status.Reason);
    }

    [Fact]
    public void AnUnreadableTimestampDoesNotDiscardTheFile()
    {
        var status = BackendStatusFile.Parse(
            "requested\tcpu\nreason\trequested\nrecorded-at\tyesterday\n");

        Assert.NotNull(status);
        Assert.Equal(DateTimeOffset.UnixEpoch, status.RecordedAt);
    }

    [Fact]
    public void TheTimestampIsReadAsUtcRegardlessOfTheMachinesZone()
    {
        // DateTimeOffset.TryParse would otherwise attach the local offset to a
        // value the engine wrote in UTC, which shifts it by hours.
        var status = BackendStatusFile.Parse(
            "requested\tcpu\nreason\trequested\nrecorded-at\t2025-07-31T22:13:20Z\n");

        Assert.NotNull(status);
        Assert.Equal(TimeSpan.Zero, status.RecordedAt.Offset);
        Assert.Equal(22, status.RecordedAt.Hour);
    }

    [Fact]
    public void TheFileSitsWithTheOtherPerUserData()
    {
        Assert.EndsWith(
            Path.Combine("Ohagey", "backend-status.tsv"),
            BackendStatusFile.Path);
    }

    [Fact]
    public void ReadingWhenTheEngineHasNeverRunIsNotAnError()
    {
        // The normal state on a fresh install. Returning null rather than
        // throwing is what lets the UI say "not started yet".
        var missing = BackendStatusFile.Read();
        Assert.True(missing is null || missing.Requested is Backend.Cpu or Backend.Cuda or Backend.Vulkan);
    }
}

public class BackendDescriptionTests
{
    private static BackendStatus Status(
        Backend requested,
        Backend? effective,
        BackendSelectionReason reason,
        string? detail = null) =>
        new() { Requested = requested, Effective = effective, Reason = reason, Detail = detail };

    [Fact]
    public void SaysNothingHasRunYetWhenThereIsNoFile()
    {
        var text = BackendState.Describe(null, Backend.Cpu);
        Assert.Contains("まだ起動していません", text);
    }

    [Fact]
    public void ANormalSelectionJustNamesTheBackend()
    {
        var text = BackendState.Describe(
            Status(Backend.Cuda, Backend.Cuda, BackendSelectionReason.Requested),
            Backend.Cuda);

        Assert.Contains("CUDA", text);
        Assert.DoesNotContain("エラー", text);
    }

    [Fact]
    public void AFallbackIsNeverLeftUnmentioned()
    {
        // The requirement decision 0028 states outright: a user who chose CUDA
        // and got CPU must be able to find out why.
        var text = BackendState.Describe(
            Status(Backend.Cuda, Backend.Cpu, BackendSelectionReason.LoadFailed, "126"),
            Backend.Cuda);

        Assert.Contains("CUDA", text);
        Assert.Contains("CPU", text);
        Assert.Contains("126", text);
    }

    [Fact]
    public void ErrorOneTwentySixPointsAtTheDriverRatherThanTheNumber()
    {
        var text = BackendState.Describe(
            Status(Backend.Cuda, Backend.Cpu, BackendSelectionReason.LoadFailed, "126"),
            Backend.Cuda);

        Assert.Contains("ドライバー", text);
    }

    [Fact]
    public void ABackendThatWasNeverInstalledSaysSo()
    {
        // Different advice from a load failure: this one the installer fixes.
        var text = BackendState.Describe(
            Status(Backend.Vulkan, Backend.Cpu, BackendSelectionReason.NotInstalled),
            Backend.Vulkan);

        Assert.Contains("インストール", text);
    }

    [Fact]
    public void NoBackendAtAllMentionsThatZenzaiIsOff()
    {
        var text = BackendState.Describe(
            Status(Backend.Cpu, null, BackendSelectionReason.Unavailable),
            Backend.Cpu);

        Assert.Contains("辞書", text);
    }

    [Fact]
    public void AChangedSettingIsReportedAsPendingRatherThanAsAFallback()
    {
        // The user just switched from CPU to CUDA. The recorded status says CPU
        // — correctly, for the last run. Announcing that as a fallback would be
        // telling them CUDA failed when it has not been tried.
        var text = BackendState.Describe(
            Status(Backend.Cpu, Backend.Cpu, BackendSelectionReason.Requested),
            Backend.Cuda);

        Assert.Contains("次に起動", text);
        Assert.DoesNotContain("読み込めなかった", text);
    }
}
