namespace Barback.Core;

public enum ProgramKind { Service, Oneshot }
public enum ExecutionMode { Direct, PowerShellFile, PowerShellText, Cmd }
public enum StopMode { ConsoleBreakThenTerminate, TerminateJob }
public enum RestartPolicy { Never, Unexpected, Always }
public enum Phase { Stopped, Starting, Running, Backoff, Stopping, Exited, Fatal, Succeeded, Failed, Cancelled, Timeout, Interrupted }
public enum EndReason { Natural, UserStop, Timeout, Forced, AppInterrupted, SpawnFailed, HostFailed, AppShutdown }
public sealed record EnvironmentEntry(string Key, string? Value, bool Sensitive = false, bool Remove = false, bool NeedsInput = false);
public sealed record LaunchSpec
{
    public ExecutionMode Mode { get; init; }
    public string Executable { get; init; } = "";
    public string[] Arguments { get; init; } = [];
    public string? RawArguments { get; init; }
    public string ScriptPath { get; init; } = "";
    public string ScriptText { get; init; } = "";
    public string WorkingDirectory { get; init; } = "";
    public EnvironmentEntry[] Environment { get; init; } = [];
    public StopMode StopMode { get; init; } = StopMode.ConsoleBreakThenTerminate;
    public double StopWaitSeconds { get; init; } = 10;
    public int EncodingCodePage { get; init; } = 65001;
    public long LogSegmentBytes { get; init; } = 10 * 1024 * 1024;
    public int LogSegments { get; init; } = 3;
}
public sealed record Policy
{
    public bool Autostart { get; init; } = true;
    public RestartPolicy Restart { get; init; } = RestartPolicy.Unexpected;
    public double StartSeconds { get; init; } = 5;
    public int StartRetries { get; init; } = 3;
    public uint[] ExpectedCodes { get; init; } = [0];
    public double TimeoutSeconds { get; init; }
    public double BackoffBaseSeconds { get; init; } = 1;
    public double BackoffMaxSeconds { get; init; } = 60;
    public int StormLimit { get; init; } = 10;
    public double StormWindowSeconds { get; init; } = 600;
    public int HistoryLimit { get; init; } = 50;
}
public sealed record ProgramConfig
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; init; } = "";
    public string Group { get; init; } = "";
    public string Notes { get; init; } = "";
    public ProgramKind Kind { get; init; }
    public bool Enabled { get; init; } = true;
    public int Priority { get; init; } = 999;
    public long Version { get; init; }
    public LaunchSpec Launch { get; init; } = new();
    public Policy Policy { get; init; } = new();
    public string NameKey => Name.Trim().Normalize().ToUpperInvariant();
}
public sealed record RuntimeState
{
    public Phase Phase { get; init; } = Phase.Stopped;
    public Guid? RunId { get; init; }
    public long Generation { get; init; }
    public int? Pid { get; init; }
    public long? CreationTime { get; init; }
    public long ConfigVersion { get; init; }
    public double StartedActive { get; init; }
    public double StartedElapsed { get; init; }
    public double? ExitObservedActive { get; init; }
    public double Deadline { get; init; }
    public int StartupFailures { get; init; }
    public int BackoffExponent { get; init; }
    public double[] Restarts { get; init; } = [];
    public DateTimeOffset[] RestartUtc { get; init; } = [];
    public EndReason? StopReason { get; init; }
    public bool RestartRequested { get; init; }
    public bool CleanupFailed { get; init; }
    public bool Cleaning { get; init; }
    public bool CancelAutomaticRestart { get; init; }
    /// <summary>Set when the app stopped a running service on exit, so the next start may resume it.</summary>
    public bool ResumeAfterAppExit { get; init; }
    public uint? ExitCode { get; init; }
    public string? Error { get; init; }
    public bool Active => RunId is not null;
}
public sealed record ProgramSnapshot(ProgramConfig Config, RuntimeState Runtime, ProgramConfig? RunConfig = null, int? UnresolvedPid = null);
public sealed record RunRecord(Guid Id, Guid ProgramId, long Generation, long ConfigVersion, DateTimeOffset Started,
    DateTimeOffset? Ended = null, int? Pid = null, long? CreationTime = null, Phase Outcome = Phase.Starting,
    EndReason? Reason = null, uint? ExitCode = null, string? LogDirectory = null);
/// <summary><paramref name="ExitCode"/> is carried for notifications only and is not persisted.</summary>
public sealed record EventRecord(DateTimeOffset At, string Type, Guid? ProgramId, Guid? RunId, string Detail, uint? ExitCode = null);
public readonly record struct ClockReading(double Active, double Elapsed, DateTimeOffset Utc);
public interface IClock { ClockReading Now { get; } }
public interface IProcessRun : IAsyncDisposable
{
    Guid Id { get; }
    int Pid { get; }
    long CreationTime { get; }
    Task<uint> Exit { get; }
    Task ActivateAsync(CancellationToken cancellationToken);
    Task RequestBreakAsync(CancellationToken cancellationToken);
    Task<bool> CleanAsync(CancellationToken cancellationToken);
}
public interface IProcessHost
{
    Task<IProcessRun> PrepareAsync(Guid runId, LaunchSpec launch, string logDirectory, Action<long> logLoss, long? runOutputLimit, CancellationToken cancellationToken);
    bool IsSameProcessAlive(int pid, long creationTime);
    /// <summary>Throws when launches cannot succeed for a reason the user can fix, so a manual start fails fast with a typed error.</summary>
    void EnsureCanLaunch() { }
}
public interface IStore : IAsyncDisposable
{
    Task<IReadOnlyList<ProgramConfig>> LoadProgramsAsync();
    Task<ProgramConfig> SaveAsync(ProgramConfig config, long expectedVersion);
    Task DeleteAsync(Guid programId);
    Task<IReadOnlyList<ProgramConfig>> ImportAsync(IReadOnlyList<ProgramConfig> drafts);
    Task BeginRunAsync(RunRecord run);
    Task IdentifyRunAsync(Guid runId, int pid, long creationTime);
    Task EndRunAsync(Guid runId, Phase outcome, EndReason reason, uint? code);
    Task SaveRuntimeAsync(Guid id, RuntimeState state);
    Task<IReadOnlyDictionary<Guid, RuntimeState>> LoadRuntimeAsync();
    Task<IReadOnlyList<RunRecord>> RunsAsync();
    Task<IReadOnlyList<EventRecord>> EventsAsync();
    Task EventAsync(EventRecord record);
    Task<bool> RecoverAsync();
    Task MarkCleanAsync();
    Task MaintainAsync() => Task.CompletedTask;
}
