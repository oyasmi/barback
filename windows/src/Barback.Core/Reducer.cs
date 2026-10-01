namespace Barback.Core;

public enum Signal { Start, Stop, Restart, Force, Prepared, Stable, Tick, Cleaned, SpawnFailed, CleanupFailed, CleanupStarted, ClearFailure }
public enum Effect { Launch, Break, Terminate, Schedule, Finish }
public sealed record MachineEvent(Signal Signal, Guid? RunId = null, long Generation = 0, uint? ExitCode = null, string? Error = null, int? Pid = null, EndReason? Reason = null, long? CreationTime = null, double? ObservedActive = null);
public sealed record Transition(RuntimeState State, Effect[] Effects);
public static class Reducer
{
    public static Transition Apply(RuntimeState s, MachineEvent e, ProgramConfig c, ClockReading now)
    {
        Transition Return(RuntimeState state, params Effect[] effects) => new(state, effects);
        if (e.RunId is not null && (e.RunId != s.RunId || e.Generation != s.Generation)) return Return(s);
        var p = c.Policy;
        RuntimeState NewRun(RuntimeState old) => old with
        {
            Phase = Phase.Starting,
            RunId = Guid.NewGuid(),
            Generation = old.Generation + 1,
            ConfigVersion = c.Version,
            Pid = null,
            CreationTime = null,
            ExitCode = null,
            Error = null,
            StopReason = null,
            CleanupFailed = false,
            Cleaning = false,
            CancelAutomaticRestart = false,
            ExitObservedActive = null,
            RestartRequested = false,
            ResumeAfterAppExit = false,
            StartedActive = now.Active,
            StartedElapsed = now.Elapsed,
            Deadline = double.PositiveInfinity
        };
        switch (e.Signal)
        {
            case Signal.Start:
                if (s.Active || s.Phase == Phase.Backoff || !c.Enabled) return Return(s);
                return Return(NewRun(s with { StartupFailures = 0, BackoffExponent = 0, Restarts = [], RestartUtc = [] }), Effect.Launch);
            case Signal.ClearFailure:
                return s.Phase == Phase.Fatal ? Return(s with { Phase = Phase.Stopped, Error = null, Restarts = [], RestartUtc = [] }) : Return(s);
            case Signal.CleanupStarted:
                return Return(s with { Cleaning = true, ExitObservedActive = e.ObservedActive });
            case Signal.Restart:
                if (c.Kind == ProgramKind.Oneshot) return Return(s);
                if (s.Cleaning && s.StopReason is null) return Return(s with { RestartRequested = true, CancelAutomaticRestart = false });
                if (!s.Active) return Apply(s with { Phase = Phase.Stopped }, new(Signal.Start), c, now);
                if (s.Phase == Phase.Stopping) return Return(s with { RestartRequested = true });
                return Return(s with { Phase = Phase.Stopping, StopReason = EndReason.UserStop, RestartRequested = true, Deadline = now.Elapsed + c.Launch.StopWaitSeconds }, c.Launch.StopMode == StopMode.TerminateJob ? Effect.Terminate : Effect.Break, Effect.Schedule);
            case Signal.Stop:
                if (s.Cleaning && s.StopReason is null) return Return(s with { RestartRequested = false, CancelAutomaticRestart = true });
                if (!s.Active)
                {
                    // Stop only cancels a pending retry; terminal outcomes such as Fatal survive until cleared or restarted.
                    if (s.Phase == Phase.Backoff) return Return(s with { Phase = Phase.Stopped, RestartRequested = false });
                    return s.RestartRequested ? Return(s with { RestartRequested = false }) : Return(s);
                }
                if (s.Phase == Phase.Stopping) return Return(s with { RestartRequested = false });
                return Return(s with { Phase = Phase.Stopping, StopReason = e.Reason ?? EndReason.UserStop, RestartRequested = false, Deadline = now.Elapsed + c.Launch.StopWaitSeconds }, c.Launch.StopMode == StopMode.TerminateJob ? Effect.Terminate : Effect.Break, Effect.Schedule);
            case Signal.Force:
                if (s.Cleaning && s.StopReason is null) return Return(s with { CancelAutomaticRestart = true }, Effect.Terminate);
                if (!s.Active) return Return(s);
                return Return(s with { Phase = Phase.Stopping, StopReason = s.StopReason ?? EndReason.Forced, Deadline = double.PositiveInfinity, CleanupFailed = false }, Effect.Terminate);
            case Signal.Prepared:
                if (s.Phase != Phase.Starting) return Return(s);
                return Return(s with
                {
                    Pid = e.Pid,
                    CreationTime = e.CreationTime,
                    StartedActive = now.Active,
                    StartedElapsed = now.Elapsed,
                    Deadline = now.Active + p.StartSeconds,
                    Phase = c.Kind == ProgramKind.Oneshot || p.StartSeconds == 0 ? Phase.Running : Phase.Starting
                }, Effect.Schedule);
            case Signal.Tick:
                if (s.Cleaning) return Return(s);
                if (s.Phase == Phase.Backoff && now.Active >= s.Deadline) return Return(NewRun(s), Effect.Launch);
                if (s.Phase == Phase.Starting && s.Pid is not null && now.Active >= s.Deadline)
                    return Return(s with { Phase = Phase.Running, StartupFailures = 0, Deadline = double.PositiveInfinity }, Effect.Schedule);
                if (s.Phase == Phase.Stopping && now.Elapsed >= s.Deadline)
                    return Return(s with { Deadline = double.PositiveInfinity }, Effect.Terminate);
                if (s.Phase == Phase.Running && c.Kind == ProgramKind.Oneshot && p.TimeoutSeconds > 0 && now.Elapsed - s.StartedElapsed >= p.TimeoutSeconds)
                    return Apply(s, new(Signal.Stop, Reason: EndReason.Timeout), c, now);
                if (s.Phase == Phase.Running && now.Active - s.StartedActive >= 60 && s.BackoffExponent != 0)
                    return Return(s with { BackoffExponent = 0 });
                return Return(s);
            case Signal.CleanupFailed:
                return Return(s with { Phase = Phase.Stopping, CleanupFailed = true, Error = e.Error, Deadline = double.PositiveInfinity });
            case Signal.SpawnFailed:
            case Signal.Cleaned:
                var ended = s with { RunId = null, Pid = null, ExitCode = e.ExitCode, Error = e.Error, CleanupFailed = false, Cleaning = false, Deadline = double.PositiveInfinity };
                if (s.StopReason is not null)
                {
                    var phase = c.Kind == ProgramKind.Service ? Phase.Stopped : s.StopReason == EndReason.Timeout ? Phase.Timeout : Phase.Cancelled;
                    ended = ended with { Phase = phase };
                    if (s.RestartRequested && c.Enabled) return Return(NewRun(ended), Effect.Finish, Effect.Launch);
                    return Return(ended, Effect.Finish);
                }
                if (c.Kind == ProgramKind.Oneshot)
                    return Return(ended with { Phase = e.Signal == Signal.Cleaned && e.Reason != EndReason.HostFailed && e.ExitCode is uint code && p.ExpectedCodes.Contains(code) ? Phase.Succeeded : Phase.Failed }, Effect.Finish);
                if (s.RestartRequested) return Return(NewRun(ended with { StartupFailures = 0, BackoffExponent = 0 }), Effect.Finish, Effect.Launch);
                if (s.CancelAutomaticRestart) return Return(ended with { Phase = Phase.Stopped }, Effect.Finish);
                var early = s.Phase == Phase.Starting && (s.Pid is null || (s.ExitObservedActive ?? now.Active) - s.StartedActive < p.StartSeconds);
                var retry = early || p.Restart == RestartPolicy.Always || (p.Restart == RestartPolicy.Unexpected && (e.ExitCode is null || !p.ExpectedCodes.Contains(e.ExitCode.Value)));
                if (!retry) return Return(ended with { Phase = Phase.Exited }, Effect.Finish);
                if (early && s.StartupFailures >= p.StartRetries) return Return(ended with { Phase = Phase.Fatal, Error = e.Error ?? "Startup retries exhausted." }, Effect.Finish);
                var restarts = s.Restarts.Where(t => now.Active - t < p.StormWindowSeconds).ToArray();
                if (restarts.Length >= p.StormLimit) return Return(ended with { Phase = Phase.Fatal, Error = "Automatic restart storm limit reached." }, Effect.Finish);
                var exponent = s.Pid is not null && (s.ExitObservedActive ?? now.Active) - s.StartedActive >= 60 ? 0 : s.BackoffExponent;
                var delay = Math.Min(p.BackoffMaxSeconds, p.BackoffBaseSeconds * Math.Pow(2, Math.Min(30, exponent)));
                return Return(ended with
                {
                    Phase = Phase.Backoff,
                    StartupFailures = early ? s.StartupFailures + 1 : 0,
                    BackoffExponent = exponent + 1,
                    Restarts = [.. restarts, now.Active],
                    RestartUtc = [.. s.RestartUtc.Where(t => now.Utc - t < TimeSpan.FromSeconds(p.StormWindowSeconds) || now.Utc < t), now.Utc],
                    Deadline = now.Active + delay
                }, Effect.Finish, Effect.Schedule);
        }
        return Return(s);
    }
}
