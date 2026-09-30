using Barback.Core;
using System.Text.Json;

namespace Barback.App;

// Shared by the workbench and tray. Labels are resource keys, not core enum names.
public sealed record ProgramAction(string Label, Signal? Signal, bool Confirm = false);

public static class ProgramActionPolicy
{
    public static ProgramAction Primary(ProgramSnapshot item)
    {
        var state = item.Runtime;
        if (state.CleanupFailed) return new("RetryCleanup", Signal.Force);
        if (state.Cleaning || state.Phase == Phase.Stopping) return new("WaitingStop", null);
        if (state.Phase == Phase.Backoff) return new("StopRetry", Signal.Stop);
        if (state.Active) return new(item.Config.Kind == ProgramKind.Oneshot ? "CancelRun" : "StopService", Signal.Stop);
        if (!item.Config.Enabled) return new("Disabled", null);
        if (state.Phase == Phase.Interrupted && item.Config.Kind == ProgramKind.Oneshot) return new("RunAgain", Signal.Start, true);
        if (state.Phase == Phase.Fatal) return new("Retry", Signal.Start);
        return new(item.Config.Kind == ProgramKind.Oneshot ? "RunCommand" : "StartService", Signal.Start);
    }

    public static bool CanRestart(ProgramSnapshot item) => item.Config.Kind == ProgramKind.Service && item.Config.Enabled
        && item.Runtime.Active && item.Runtime.Phase is Phase.Starting or Phase.Running
        && !item.Runtime.Cleaning && !item.Runtime.CleanupFailed;

    public static bool NeedsAttention(ProgramSnapshot item) => item.Runtime.CleanupFailed
        || item.Runtime.Phase is Phase.Fatal or Phase.Failed or Phase.Timeout or Phase.Interrupted;

    public static bool HasPendingConfiguration(ProgramSnapshot item) => item.Runtime.Active && item.Config.Version != item.Runtime.ConfigVersion
        && (item.RunConfig is null || JsonSerializer.Serialize(new { item.Config.Launch, item.Config.Policy }) != JsonSerializer.Serialize(new { item.RunConfig.Launch, item.RunConfig.Policy }));

    public static bool CanRerun(RunRecord run, ProgramSnapshot? item) => run.Ended is not null
        && item is not null && item.Config.Id == run.ProgramId && item.Config.Kind == ProgramKind.Oneshot
        && item.Config.Enabled && !item.Runtime.Active && item.Runtime.Phase != Phase.Backoff && !item.Runtime.CleanupFailed;

    public static string Outcome(RunRecord run) => run.Ended is null ? "RunInProgress" : run.Outcome switch
    {
        Phase.Succeeded => "RunSuccess",
        Phase.Failed or Phase.Fatal => "RunFailed",
        Phase.Timeout => "RunTimeout",
        Phase.Interrupted => "RunInterrupted",
        Phase.Cancelled or Phase.Stopped => "RunCancelled",
        Phase.Exited => "RunExited",
        _ => "RunUnknown"
    };
}
