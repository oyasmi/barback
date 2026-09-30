using Barback.App;
using Barback.Core;
namespace Barback.Core.Tests;

public class ProgramActionTests
{
    private static ProgramSnapshot Item(ProgramKind kind = ProgramKind.Service, Phase phase = Phase.Stopped, bool active = false, bool enabled = true)
        => new(new() { Kind = kind, Enabled = enabled, Version = 2 }, new() { Phase = phase, RunId = active ? Guid.NewGuid() : null, ConfigVersion = 2 });

    [Theory]
    [InlineData(ProgramKind.Service, Phase.Stopped, false, "StartService", Signal.Start)]
    [InlineData(ProgramKind.Service, Phase.Running, true, "StopService", Signal.Stop)]
    [InlineData(ProgramKind.Oneshot, Phase.Running, true, "CancelRun", Signal.Stop)]
    [InlineData(ProgramKind.Service, Phase.Backoff, false, "StopRetry", Signal.Stop)]
    [InlineData(ProgramKind.Service, Phase.Fatal, false, "Retry", Signal.Start)]
    [InlineData(ProgramKind.Oneshot, Phase.Succeeded, false, "RunCommand", Signal.Start)]
    public void PrimaryActionFollowsOwnershipAndIntent(ProgramKind kind, Phase phase, bool active, string label, Signal signal)
    {
        var action = ProgramActionPolicy.Primary(Item(kind, phase, active));
        Assert.Equal(label, action.Label); Assert.Equal(signal, action.Signal);
    }
    [Fact]
    public void DisabledOwnedRunStillCanStopButCannotRestart()
    {
        var item = Item(active: true, phase: Phase.Running, enabled: false);
        Assert.Equal(Signal.Stop, ProgramActionPolicy.Primary(item).Signal);
        Assert.False(ProgramActionPolicy.CanRestart(item));
        Assert.Null(ProgramActionPolicy.Primary(Item(enabled: false)).Signal);
    }
    [Fact]
    public void CleanupAndStoppingTakePrecedenceOverDisabledAndActive()
    {
        var item = Item(active: true, enabled: false);
        Assert.Equal(Signal.Force, ProgramActionPolicy.Primary(item with { Runtime = item.Runtime with { CleanupFailed = true } }).Signal);
        Assert.Null(ProgramActionPolicy.Primary(item with { Runtime = item.Runtime with { Cleaning = true } }).Signal);
        Assert.Null(ProgramActionPolicy.Primary(item with { Runtime = item.Runtime with { Phase = Phase.Stopping } }).Signal);
    }
    [Fact]
    public void InterruptedOneshotRequiresConfirmation()
        => Assert.True(ProgramActionPolicy.Primary(Item(ProgramKind.Oneshot, Phase.Interrupted)).Confirm);
    [Fact]
    public void MetadataChangesDoNotRequireRestartButLaunchChangesDo()
    {
        var item = Item(active: true, phase: Phase.Running);
        var original = item.Config;
        item = item with { RunConfig = original, Config = original with { Version = 3, Name = "Renamed", Notes = "New notes", Group = "Group" } };
        Assert.False(ProgramActionPolicy.HasPendingConfiguration(item));
        Assert.True(ProgramActionPolicy.HasPendingConfiguration(item with { Config = item.Config with { Launch = original.Launch with { EncodingCodePage = 1200 } } }));
    }
    [Fact]
    public void OnlyCompletedExistingEnabledIdleOneshotCanRerun()
    {
        var item = Item(ProgramKind.Oneshot);
        var run = new RunRecord(Guid.NewGuid(), item.Config.Id, 1, 1, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, Outcome: Phase.Succeeded);
        Assert.True(ProgramActionPolicy.CanRerun(run, item));
        Assert.False(ProgramActionPolicy.CanRerun(run, null));
        Assert.False(ProgramActionPolicy.CanRerun(run with { Ended = null }, item));
        Assert.False(ProgramActionPolicy.CanRerun(run, item with { Config = item.Config with { Enabled = false } }));
        Assert.False(ProgramActionPolicy.CanRerun(run, item with { Config = item.Config with { Kind = ProgramKind.Service } }));
        Assert.False(ProgramActionPolicy.CanRerun(run, item with { Runtime = item.Runtime with { RunId = Guid.NewGuid() } }));
        Assert.False(ProgramActionPolicy.CanRerun(run, item with { Runtime = item.Runtime with { CleanupFailed = true } }));
    }
    [Fact]
    public void IncompleteRunIsNeverPresentedAsSuccess()
    {
        var run = new RunRecord(Guid.NewGuid(), Guid.NewGuid(), 1, 1, DateTimeOffset.UtcNow, Outcome: Phase.Succeeded);
        Assert.Equal("RunInProgress", ProgramActionPolicy.Outcome(run));
        Assert.Equal("RunSuccess", ProgramActionPolicy.Outcome(run with { Ended = DateTimeOffset.UtcNow }));
    }
}
