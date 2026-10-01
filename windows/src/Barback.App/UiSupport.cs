using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using Barback.Core;

namespace Barback.App;

public sealed class Loc(string key) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => Text.Get(key);
}

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
}

public sealed class AsyncCommand(Func<object?, Task> execute, Func<object?, bool>? canExecute = null, Action<Exception>? error = null) : ICommand
{
    private bool busy;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => !busy && (canExecute?.Invoke(parameter) ?? true);
    public async void Execute(object? parameter)
    {
        if (!CanExecute(parameter)) return;
        busy = true; Refresh();
        try { await execute(parameter); }
        catch (Exception ex) { if (error is not null) error(ex); else await MainWindow.RunGuardedAsync(() => Task.FromException(ex)); }
        finally { busy = false; Refresh(); }
    }
    public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class ProgramRow(ProgramSnapshot snapshot, Func<Guid, Task> primary, Func<Guid, Task> more, Action<Exception> error) : Observable
{
    public ProgramSnapshot Snapshot { get; private set; } = snapshot;
    public Guid Id => Snapshot.Config.Id;
    public string Name => Snapshot.Config.Name;
    public string Group => string.IsNullOrWhiteSpace(Snapshot.Config.Group) ? Text.Get("Ungrouped") : Snapshot.Config.Group;
    public string Kind => Text.Get(Snapshot.Config.Kind == ProgramKind.Service ? "ServiceKind" : "OneshotKind");
    public string Status => !Snapshot.Config.Enabled && !Snapshot.Runtime.Active && Snapshot.Runtime.Phase != Phase.Backoff ? Text.Get("Disabled")
        : Snapshot.Runtime.CleanupFailed ? Text.Get("CleanupFailed") : Snapshot.Runtime.Cleaning ? Text.Get("CleaningChildren")
        : Snapshot.Config.Kind == ProgramKind.Oneshot && Snapshot.Runtime.Phase == Phase.Running ? Text.Get("Executing") : Text.Status(Snapshot.Runtime.Phase);
    public string Detail { get; private set; } = "";
    public bool Attention => ProgramActionPolicy.NeedsAttention(Snapshot);
    public string StatusBrush => Attention ? "DangerBrush" : Snapshot.Runtime.Phase is Phase.Starting or Phase.Stopping or Phase.Backoff || Snapshot.Runtime.Cleaning ? "WarningBrush"
        : Snapshot.Runtime.Phase is Phase.Running or Phase.Succeeded ? "SuccessBrush" : "SecondaryTextBrush";
    public Brush Color => (Brush)Application.Current.FindResource(StatusBrush);
    public string StatusIcon => Attention ? "\uE7BA" : Snapshot.Runtime.Phase is Phase.Starting or Phase.Stopping or Phase.Backoff || Snapshot.Runtime.Cleaning ? "\uE823"
        : Snapshot.Runtime.Phase == Phase.Succeeded ? "\uE73E" : "\uEA3A";
    public string ActionLabel => Text.Get(ProgramActionPolicy.Primary(Snapshot).Label);
    public string ActionName => ActionLabel + " · " + Name;
    public string MoreName => Text.Get("MoreActions") + " · " + Name;
    public bool CanAct => ProgramActionPolicy.Primary(Snapshot).Signal is not null;
    public bool Pending => ProgramActionPolicy.HasPendingConfiguration(Snapshot);
    public AsyncCommand PrimaryCommand { get; } = new(_ => primary(snapshot.Config.Id), _ => true, error);
    public AsyncCommand MoreCommand { get; } = new(_ => more(snapshot.Config.Id), error: error);
    public void Update(ProgramSnapshot value, ClockReading clock)
    {
        Snapshot = value;
        var state = value.Runtime;
        Detail = state.Error ?? (state.Phase == Phase.Backoff ? Text.Format("RetryIn", Math.Max(0, (int)Math.Ceiling(state.Deadline - clock.Active)), state.StartupFailures)
            : state.Phase == Phase.Stopping ? Text.Format("StoppingIn", double.IsFinite(state.Deadline) ? Math.Max(0, (int)Math.Ceiling(state.Deadline - clock.Elapsed)) : 0)
            : state.Active ? Text.Format("RunningFor", Duration(clock.Elapsed - state.StartedElapsed))
            : value.KindLabel() + " · " + (state.ExitCode is uint code ? Text.Format("LastExitCode", code) : Text.Get("ManualRun")));
        Changed(""); PrimaryCommand.Refresh(); MoreCommand.Refresh();
    }
    public void RefreshTheme() => Changed(nameof(Color));
    public static string Duration(double seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, double.IsFinite(seconds) ? seconds : 0));
        return time.TotalHours >= 1 ? Text.Format("HoursMinutes", (int)time.TotalHours, time.Minutes)
            : time.TotalMinutes >= 1 ? Text.Format("MinutesSeconds", (int)time.TotalMinutes, time.Seconds) : Text.Format("Seconds", (int)time.TotalSeconds);
    }
}

public static class UiExtensions
{
    public static string KindLabel(this ProgramSnapshot value) => Text.Get(value.Config.Kind == ProgramKind.Service ? "ServiceKind" : "OneshotKind");
}

public sealed record HistoryRow(RunRecord Run, string ProgramName)
{
    public Guid ProgramId => Run.ProgramId;
    public DateTimeOffset Started => Run.Started.ToLocalTime();
    public string DisplayTime => Started.ToString("MM-dd HH:mm:ss", CultureInfo.CurrentUICulture);
    public string DisplayOutcome => Text.Get(Run.Ended is not null && Run.Reason == EndReason.AppShutdown && Run.Outcome is Phase.Stopped or Phase.Cancelled ? "RunStoppedOnExit" : ProgramActionPolicy.Outcome(Run));
    public string DisplayCode => Run.ExitCode is uint code ? $"{code} (0x{code:X8})" : Text.Get("Unknown");
    public string Duration => Run.Ended is DateTimeOffset ended ? ProgramRow.Duration((ended - Run.Started).TotalSeconds) : "—";
    public string Version => $"v{Run.ConfigVersion}";
}
