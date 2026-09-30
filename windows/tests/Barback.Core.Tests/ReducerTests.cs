using Barback.Core;
namespace Barback.Core.Tests;

public class ReducerTests
{
    private static readonly ClockReading Now = new(100, 100, DateTimeOffset.Parse("2026-09-30T00:00:00Z"));
    private static ProgramConfig Config(ProgramKind kind = ProgramKind.Service, RestartPolicy policy = RestartPolicy.Unexpected) => new() { Kind = kind, Policy = new() { Restart = policy } };
    private static RuntimeState Running() => new() { Phase = Phase.Running, RunId = Guid.NewGuid(), Generation = 1, StartedActive = 1, StartedElapsed = 1, Pid = 42 };
    [Theory]
    [InlineData(RestartPolicy.Never, 0, false)]
    [InlineData(RestartPolicy.Never, 1, false)]
    [InlineData(RestartPolicy.Unexpected, 0, false)]
    [InlineData(RestartPolicy.Unexpected, 1, true)]
    [InlineData(RestartPolicy.Always, 0, true)]
    [InlineData(RestartPolicy.Always, 1, true)]
    public void StableExitPolicy(RestartPolicy policy, uint code, bool retry)
    {
        var result = Reducer.Apply(Running(), new(Signal.Cleaned, ExitCode: code), Config(policy: policy), Now);
        Assert.Equal(retry ? Phase.Backoff : Phase.Exited, result.State.Phase); Assert.Contains(Effect.Finish, result.Effects);
    }
    [Fact]
    public void InitialAttemptPlusThreeRetriesHaveOneTwoFourBackoff()
    {
        var c = Config(); var s = Reducer.Apply(new(), new(Signal.Start), c, Now).State; var time = Now;
        for (int i = 0; i < 4; i++)
        {
            var t = Reducer.Apply(s, new(Signal.SpawnFailed, Error: "missing executable"), c, time);
            if (i == 3) { Assert.Equal(Phase.Fatal, t.State.Phase); Assert.DoesNotContain(Effect.Launch, t.Effects); break; }
            Assert.Equal(Math.Pow(2, i), t.State.Deadline - time.Active); Assert.Equal(i + 1, t.State.StartupFailures);
            time = time with { Active = t.State.Deadline, Elapsed = t.State.Deadline };
            s = Reducer.Apply(t.State, new(Signal.Tick), c, time).State; Assert.Equal(Phase.Starting, s.Phase);
        }
    }
    [Theory]
    [InlineData(RestartPolicy.Never)]
    [InlineData(RestartPolicy.Unexpected)]
    [InlineData(RestartPolicy.Always)]
    public void EarlyZeroExitIsStartupFailure(RestartPolicy policy)
    {
        var s = Running() with { Phase = Phase.Starting, StartedActive = Now.Active - 1 };
        var t = Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 0), Config(policy: policy), Now);
        Assert.Equal(Phase.Backoff, t.State.Phase); Assert.Equal(1, t.State.StartupFailures);
    }
    [Fact]
    public void EleventhAutomaticRestartIsBlocked()
    {
        var c = Config(policy: RestartPolicy.Always); var s = Running();
        for (int i = 0; i < 10; i++) { var t = Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 1), c, Now); Assert.Equal(Phase.Backoff, t.State.Phase); s = t.State with { Phase = Phase.Running, RunId = Guid.NewGuid() }; }
        Assert.Equal(Phase.Fatal, Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 1), c, Now).State.Phase);
    }
    [Fact]
    public void ManualStopNeverRestartsAndRepeatedStopKeepsDeadline()
    {
        var c = Config(policy: RestartPolicy.Always); var s = Reducer.Apply(Running(), new(Signal.Stop), c, Now).State;
        var again = Reducer.Apply(s, new(Signal.Stop), c, Now with { Elapsed = 105 }); Assert.Equal(s.Deadline, again.State.Deadline);
        var t = Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 1), c, Now); Assert.Equal(Phase.Stopped, t.State.Phase); Assert.DoesNotContain(Effect.Launch, t.Effects);
    }
    [Fact]
    public void StopCancelsPendingRestart()
    {
        var c = Config(); var s = Reducer.Apply(Running(), new(Signal.Restart), c, Now).State;
        Assert.True(s.RestartRequested); s = Reducer.Apply(s, new(Signal.Stop), c, Now).State;
        Assert.DoesNotContain(Effect.Launch, Reducer.Apply(s, new(Signal.Cleaned), c, Now).Effects);
    }
    [Fact]
    public void LateCallbacksAreIgnoredEvenWhenPidMatches()
    {
        var s = Running(); var e = new MachineEvent(Signal.Cleaned, Guid.NewGuid(), s.Generation, 0, Pid: s.Pid);
        Assert.Equal(s, Reducer.Apply(s, e, Config(), Now).State);
        Assert.Equal(s, Reducer.Apply(s, new(Signal.Cleaned, s.RunId, s.Generation - 1, 0), Config(), Now).State);
    }
    [Theory]
    [InlineData(EndReason.UserStop, Phase.Cancelled)]
    [InlineData(EndReason.Timeout, Phase.Timeout)]
    public void AcceptedCancellationCannotBecomeSuccess(EndReason reason, Phase expected)
    {
        var c = Config(ProgramKind.Oneshot); var s = Reducer.Apply(Running(), new(Signal.Stop, Reason: reason), c, Now).State;
        Assert.Equal(Phase.Stopping, s.Phase); Assert.Equal(expected, Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 0), c, Now).State.Phase);
    }
    [Theory]
    [InlineData(0u, Phase.Succeeded)]
    [InlineData(259u, Phase.Failed)]
    [InlineData(0xC000013Au, Phase.Failed)]
    public void OneShotPreservesDwordAndNeverRetries(uint code, Phase phase)
    {
        var t = Reducer.Apply(Running(), new(Signal.Cleaned, ExitCode: code), Config(ProgramKind.Oneshot), Now);
        Assert.Equal(phase, t.State.Phase); Assert.Equal(code, t.State.ExitCode); Assert.DoesNotContain(Effect.Schedule, t.Effects);
    }
    [Fact]
    public void SleepUsesElapsedForOneShotAndActiveForService()
    {
        var c = Config(ProgramKind.Oneshot) with { Policy = new() { TimeoutSeconds = 60 } }; var s = Running() with { StartedElapsed = 0 };
        var asleep = Now with { Active = 10, Elapsed = 300 };
        Assert.Equal(EndReason.Timeout, Reducer.Apply(s, new(Signal.Tick), c, asleep).State.StopReason);
        var starting = Running() with { Phase = Phase.Starting, Deadline = 20 };
        Assert.Equal(Phase.Starting, Reducer.Apply(starting, new(Signal.Tick), Config(), asleep).State.Phase);
    }
    [Fact]
    public void ExitAfterThresholdDoesNotDependOnTimerDeliveryOrder()
    {
        var c = Config(policy: RestartPolicy.Never); var s = Running() with { Phase = Phase.Starting, StartedActive = Now.Active - 6 };
        s = Reducer.Apply(s, new(Signal.CleanupStarted, ObservedActive: Now.Active), c, Now).State;
        Assert.Equal(Phase.Exited, Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 0), c, Now).State.Phase);
    }
    [Fact]
    public void SlowTreeCleanupDoesNotTurnEarlyExitIntoStableRun()
    {
        var c = Config(policy: RestartPolicy.Never); var s = Running() with { Phase = Phase.Starting, StartedActive = Now.Active - 1 };
        s = Reducer.Apply(s, new(Signal.CleanupStarted, ObservedActive: Now.Active), c, Now).State;
        Assert.Equal(Phase.Backoff, Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 0), c, Now with { Active = Now.Active + 10 }).State.Phase);
    }
    [Fact]
    public void NaturalOneShotExitConfirmedBeforeCancelKeepsSuccess()
    {
        var c = Config(ProgramKind.Oneshot); var s = Reducer.Apply(Running(), new(Signal.CleanupStarted), c, Now).State;
        s = Reducer.Apply(s, new(Signal.Stop), c, Now).State; Assert.Null(s.StopReason);
        Assert.Equal(Phase.Succeeded, Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 0), c, Now).State.Phase);
    }
    [Fact]
    public void StopDuringNaturalTreeCleanupCancelsAutomaticRestart()
    {
        var c = Config(policy: RestartPolicy.Always); var s = Reducer.Apply(Running(), new(Signal.CleanupStarted), c, Now).State;
        s = Reducer.Apply(s, new(Signal.Stop), c, Now).State;
        var ended = Reducer.Apply(s, new(Signal.Cleaned, ExitCode: 1), c, Now); Assert.Equal(Phase.Stopped, ended.State.Phase); Assert.DoesNotContain(Effect.Launch, ended.Effects); Assert.DoesNotContain(Effect.Schedule, ended.Effects);
    }
    [Fact]
    public void ExplicitStartAfterCleanupCancellationRestoresRestartPolicy()
    {
        var c = Config(policy: RestartPolicy.Always) with { Policy = new() { Restart = RestartPolicy.Always, StartSeconds = 0 } };
        var state = Reducer.Apply(Running(), new(Signal.CleanupStarted, ObservedActive: Now.Active), c, Now).State;
        state = Reducer.Apply(state, new(Signal.Stop), c, Now).State;
        state = Reducer.Apply(state, new(Signal.Cleaned, ExitCode: 1), c, Now).State;
        state = Reducer.Apply(state, new(Signal.Start), c, Now).State;
        Assert.False(state.CancelAutomaticRestart); Assert.False(state.Cleaning); Assert.Null(state.ExitObservedActive); Assert.Null(state.CreationTime);
        state = Reducer.Apply(state, new(Signal.Prepared, Pid: 42, CreationTime: 200), c, Now).State;
        Assert.Equal(Phase.Backoff, Reducer.Apply(state, new(Signal.Cleaned, ExitCode: 1), c, Now).State.Phase);
    }
    [Fact]
    public void StableRunResetsFutureBackoffEvenWhenResetTimerIsLate()
    {
        var c = Config(policy: RestartPolicy.Always) with { Policy = new() { Restart = RestartPolicy.Always, StartSeconds = 0 } };
        var state = Running() with { BackoffExponent = 5 };
        state = Reducer.Apply(state, new(Signal.CleanupStarted, ObservedActive: Now.Active), c, Now).State;
        state = Reducer.Apply(state, new(Signal.Cleaned, ExitCode: 1), c, Now).State;
        Assert.Equal(Now.Active + 1, state.Deadline); Assert.Equal(1, state.BackoffExponent);
        var retryTime = Now with { Active = state.Deadline, Elapsed = state.Deadline };
        state = Reducer.Apply(state, new(Signal.Tick), c, retryTime).State;
        state = Reducer.Apply(state, new(Signal.Prepared, Pid: 43), c, retryTime).State;
        var exitTime = retryTime with { Active = retryTime.Active + 1, Elapsed = retryTime.Elapsed + 1 };
        state = Reducer.Apply(state, new(Signal.Cleaned, ExitCode: 1), c, exitTime).State;
        Assert.Equal(exitTime.Active + 2, state.Deadline); Assert.Equal(2, state.BackoffExponent);
    }
    [Fact]
    public void CleanupFailureRetainsOwnershipAndBlocksStart()
    {
        var s = Running(); var failed = Reducer.Apply(s, new(Signal.CleanupFailed, Error: "tree remains"), Config(), Now).State;
        Assert.True(failed.Active); Assert.True(failed.CleanupFailed); Assert.Equal(failed, Reducer.Apply(failed, new(Signal.Start), Config(), Now).State);
    }
    [Fact] public void SameCommandCannotRunConcurrently() { var s = Running(); Assert.Empty(Reducer.Apply(s, new(Signal.Start), Config(ProgramKind.Oneshot), Now).Effects); }
}
