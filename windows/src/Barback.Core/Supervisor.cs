using System.Threading.Channels;
namespace Barback.Core;

/// <summary>The only writer of runtime state. Native startup and cleanup never block the actor.</summary>
public sealed class Supervisor : IAsyncDisposable
{
    private sealed record Request(Func<Task> Action, TaskCompletionSource? Completion = null);
    private readonly Channel<Request> queue = Channel.CreateUnbounded<Request>(new() { SingleReader = true });
    private readonly Dictionary<Guid, ProgramConfig> configs = [];
    private readonly Dictionary<Guid, ProgramConfig> runConfigs = [];
    private readonly Dictionary<Guid, RuntimeState> states = [];
    private readonly Dictionary<Guid, IProcessRun> runs = [];
    private readonly HashSet<Guid> cleaning = [];
    private readonly Channel<Func<Task>> storageQueue = Channel.CreateUnbounded<Func<Task>>(new() { SingleReader = true });
    private readonly Task storageLoop;
    private readonly HashSet<Guid> deleting = [];
    private readonly Dictionary<Guid, (int Pid, long Time)> unresolved = [];
    private readonly IStore store;
    private readonly IProcessHost host;
    private readonly IClock clock;
    private readonly string logRoot;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task loop;
    private readonly Task ticker;
    private volatile ProgramSnapshot[] snapshot = [];
    private readonly List<Task> workers = [];
    private bool exiting;
    private string? publishedStorageError;
    private int startupSlots;
    private int tickQueued;
    private readonly Queue<(Guid Id, Guid RunId)> pendingStarts = [];
    private readonly HashSet<Guid> preparing = [];
    public event Action? Changed;
    public event Action<EventRecord>? Attention;
    public IReadOnlyList<ProgramSnapshot> Snapshot => snapshot;
    public string? StorageError { get; private set; }
    public Action<string, Exception>? Diagnostic { get; set; }
    public Supervisor(IStore store, IProcessHost host, IClock clock, string logRoot)
    {
        this.store = store; this.host = host; this.clock = clock; this.logRoot = logRoot;
        loop = Task.Run(ConsumeAsync); ticker = Task.Run(TickAsync); storageLoop = Task.Run(ConsumeStorageAsync);
    }
    private Task Enqueue(Func<Task> action)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.Writer.TryWrite(new(action, done))) done.SetException(new ObjectDisposedException(nameof(Supervisor)));
        return done.Task;
    }
    private void Post(Func<Task> action) => queue.Writer.TryWrite(new(action));
    private async Task ConsumeAsync()
    {
        await foreach (var r in queue.Reader.ReadAllAsync())
        {
            try { await r.Action().ConfigureAwait(false); Publish(); r.Completion?.SetResult(); }
            catch (Exception ex)
            {
                // Operation failures belong to the caller. Only the storage paths publish StorageError.
                if (r.Completion is null) await ReportInternalErrorAsync(ex).ConfigureAwait(false);
                Publish(); r.Completion?.SetException(ex);
            }
        }
    }
    private async Task ReportInternalErrorAsync(Exception ex)
    {
        try { Diagnostic?.Invoke("supervisor request failed", ex); } catch { /* diagnostics must not break the actor */ }
        try { await RecordAsync("InternalError", null, null, ex.Message).ConfigureAwait(false); } catch { }
    }
    private static bool IsStorageFailure(Exception ex) => ex is IOException or UnauthorizedAccessException or System.Data.Common.DbException;
    private async Task ReportStorageFailureAsync(Exception ex)
    {
        if (IsStorageFailure(ex)) await Enqueue(() => { StorageError = ex.Message; return Task.CompletedTask; }).ConfigureAwait(false);
    }
    private static string UnresolvedMessage(int pid) => $"Previous process (PID {pid}) may still be running; verify before retrying.";
    private void Publish()
    {
        var next = configs.Values.OrderBy(c => c.Priority).ThenBy(c => c.NameKey).ThenBy(c => c.Id)
            .Select(c => new ProgramSnapshot(c, states.GetValueOrDefault(c.Id) ?? new(), states.GetValueOrDefault(c.Id)?.Active == true ? runConfigs.GetValueOrDefault(c.Id) : null, unresolved.TryGetValue(c.Id, out var identity) ? identity.Pid : null)).ToArray();
        if (!snapshot.SequenceEqual(next) || publishedStorageError != StorageError) { snapshot = next; publishedStorageError = StorageError; Changed?.Invoke(); }
    }
    public Task InitializeAsync() => Enqueue(async () =>
    {
        foreach (var c in await store.LoadProgramsAsync().ConfigureAwait(false)) { configs[c.Id] = c; states[c.Id] = new(); }
        var saved = await store.LoadRuntimeAsync().ConfigureAwait(false); var oldRuns = await store.RunsAsync().ConfigureAwait(false);
        bool interrupted = await store.RecoverAsync().ConfigureAwait(false);
        var staleResumeFlags = new List<Guid>();
        foreach (var c in configs.Values)
        {
            var previous = saved.GetValueOrDefault(c.Id) ?? new();
            if (previous.ResumeAfterAppExit) staleResumeFlags.Add(c.Id);
            var restarts = previous.RestartUtc.Where(t => clock.Now.Utc - t < TimeSpan.FromSeconds(c.Policy.StormWindowSeconds) || clock.Now.Utc < t).ToArray();
            // Conservatively retain all recent persisted attempts for a full active-time window.
            states[c.Id] = new()
            {
                Phase = previous.Phase == Phase.Fatal ? Phase.Fatal : previous.Active && c.Kind == ProgramKind.Oneshot ? Phase.Interrupted : Phase.Stopped,
                Generation = previous.Generation,
                Error = previous.Phase == Phase.Fatal ? previous.Error : null,
                Restarts = restarts.Select(_ => clock.Now.Active).ToArray(),
                RestartUtc = restarts
            };
            var remaining = oldRuns.FirstOrDefault(r => r.ProgramId == c.Id && r.Ended is null && r.Pid is int pid && r.CreationTime is long time && host.IsSameProcessAlive(pid, time));
            if (remaining is not null) { unresolved[c.Id] = (remaining.Pid!.Value, remaining.CreationTime!.Value); states[c.Id] = states[c.Id] with { Phase = Phase.Fatal, Error = UnresolvedMessage(remaining.Pid!.Value) }; continue; }
            bool recover = !interrupted || previous.ResumeAfterAppExit || (previous.Phase is Phase.Starting or Phase.Running or Phase.Backoff && previous.StopReason is null);
            if (c.Enabled && c.Policy.Autostart && c.Kind == ProgramKind.Service && recover && previous.Phase != Phase.Fatal)
            {
                // Automatic boot must not reset storm history as explicit manual recovery does.
                var old = states[c.Id];
                if (old.Restarts.Length >= c.Policy.StormLimit) { states[c.Id] = old with { Phase = Phase.Fatal, Error = "Persisted automatic restart storm limit reached." }; continue; }
                var t = Reducer.Apply(old, new(Signal.Start), c, clock.Now);
                states[c.Id] = t.State with { Restarts = old.Restarts, RestartUtc = old.RestartUtc };
                runConfigs[c.Id] = c; QueueLaunch(c.Id);
            }
        }
        // The one-shot resume marker has been consumed; persist the cleared state so it cannot trigger a later recovery.
        foreach (var id in staleResumeFlags) { var cleared = states[id]; WriteLater(() => store.SaveRuntimeAsync(id, cleared)); }
        if (interrupted) await RecordAsync("AppInterrupted", null, null, "Previous session ended unexpectedly; one-shot commands were not rerun.", true).ConfigureAwait(false);
    });
    public async Task SaveAsync(ProgramConfig draft, long expectedVersion)
    {
        var errors = ConfigurationValidator.Validate(draft, false);
        if (errors.Count != 0) throw new ArgumentException(string.Join("\n", errors.Select(e => $"{e.Field}: {e.Message}")));
        try
        {
            var saved = await Task.Run(() => store.SaveAsync(draft, expectedVersion)).ConfigureAwait(false);
            await Enqueue(async () =>
            {
                if (deleting.Contains(saved.Id) || configs.TryGetValue(saved.Id, out var newer) && newer.Version > saved.Version) return;
                configs[saved.Id] = saved; states.TryAdd(saved.Id, new()); StorageError = null;
                await RecordAsync("ConfigSaved", saved.Id, null, "Configuration saved; active launch snapshots remain unchanged.").ConfigureAwait(false);
            }).ConfigureAwait(false);
        }
        catch (Exception ex) { await ReportStorageFailureAsync(ex).ConfigureAwait(false); throw; }
    }
    public async Task ImportAsync(IReadOnlyList<ProgramConfig> drafts)
    {
        var safe = drafts.Select(c => c with { Id = Guid.NewGuid(), Version = 0, Enabled = false, Policy = c.Policy with { Autostart = false } }).ToArray();
        foreach (var c in safe) { var errors = ConfigurationValidator.Validate(c, false); if (errors.Count > 0) throw new ArgumentException(string.Join("\n", errors.Select(e => e.Message))); }
        IReadOnlyList<ProgramConfig> saved;
        try { saved = await Task.Run(() => store.ImportAsync(safe)).ConfigureAwait(false); }
        catch (Exception ex) { await ReportStorageFailureAsync(ex).ConfigureAwait(false); throw; }
        await Enqueue(async () => { foreach (var c in saved) { configs[c.Id] = c; states[c.Id] = new(); } await RecordAsync("ConfigImported", null, null, $"Imported disabled drafts: {saved.Count}").ConfigureAwait(false); }).ConfigureAwait(false);
    }
    public async Task DeleteAsync(Guid id)
    {
        await Enqueue(() =>
        {
            if (states[id].Active || states[id].Phase == Phase.Backoff) throw new InvalidOperationException("Stop and confirm cleanup before deleting.");
            deleting.Add(id); return Task.CompletedTask;
        }).ConfigureAwait(false);
        try { await FlushWritesAsync().ConfigureAwait(false); await Task.Run(() => store.DeleteAsync(id)).ConfigureAwait(false); await Enqueue(() => { configs.Remove(id); states.Remove(id); runConfigs.Remove(id); return Task.CompletedTask; }).ConfigureAwait(false); }
        catch (Exception ex) { await ReportStorageFailureAsync(ex).ConfigureAwait(false); throw; }
        finally { await Enqueue(() => { deleting.Remove(id); return Task.CompletedTask; }).ConfigureAwait(false); }
    }
    public Task SendAsync(Guid id, Signal signal) => Enqueue(() => ApplyAsync(id, new(signal)));
    public Task BatchAsync(Signal signal) => Enqueue(async () =>
    {
        var candidates = configs.Values.Where(c => signal == Signal.Stop ? states[c.Id].Active || states[c.Id].Phase == Phase.Backoff : c.Enabled && c.Kind == ProgramKind.Service);
        var ordered = signal == Signal.Stop ? candidates.OrderByDescending(c => c.Priority).ThenBy(c => c.NameKey) : candidates.OrderBy(c => c.Priority).ThenBy(c => c.NameKey);
        foreach (var c in ordered.ToArray()) await ApplyAsync(c.Id, new(signal)).ConfigureAwait(false);
    });
    private async Task ApplyAsync(Guid id, MachineEvent e)
    {
        if (!configs.TryGetValue(id, out var config) || deleting.Contains(id)) return;
        if (exiting && e.Signal is Signal.Start or Signal.Restart) return;
        if (e.Signal is Signal.Start or Signal.Restart && unresolved.TryGetValue(id, out var previousIdentity))
        {
            if (host.IsSameProcessAlive(previousIdentity.Pid, previousIdentity.Time)) throw new InvalidOperationException(UnresolvedMessage(previousIdentity.Pid));
            unresolved.Remove(id);
        }
        if (e.Signal == Signal.ClearFailure) unresolved.Remove(id); // explicit user confirmation that the old process is gone
        var before = states[id];
        // Policies of an active run remain immutable; a fresh manual start uses latest config.
        var basis = before.Active ? runConfigs.GetValueOrDefault(id) ?? config : config;
        if (e.Signal == Signal.Start && !before.Active && before.Phase != Phase.Backoff)
        {
            var errors = ConfigurationValidator.Validate(config);
            if (errors.Count > 0) throw new ArgumentException(string.Join("\n", errors.Select(x => x.Message)));
        }
        var transition = Reducer.Apply(before, e, basis, clock.Now);
        states[id] = transition.State;
        if (transition.State == before) return;
        if (transition.Effects.Contains(Effect.Finish) && before.RunId is Guid finished)
        {
            var reason = before.StopReason ?? e.Reason ?? (e.Signal == Signal.SpawnFailed ? EndReason.SpawnFailed : EndReason.Natural);
            var outcome = before.StopReason == EndReason.Timeout ? Phase.Timeout : before.StopReason is not null ? config.Kind == ProgramKind.Oneshot ? Phase.Cancelled : Phase.Stopped : config.Kind == ProgramKind.Oneshot ? transition.State.Phase : e.Signal == Signal.SpawnFailed ? Phase.Failed : Phase.Exited;
            WriteLater(() => store.EndRunAsync(finished, outcome, reason, e.ExitCode));
            runs.Remove(id);
            cleaning.Remove(id);
            WriteLater(() => store.MaintainAsync());
            await RecordAsync("RunEnded", id, finished, $"{outcome}; reason={reason}; code={(e.ExitCode is uint code ? $"0x{code:X8}" : "unknown")}", outcome is Phase.Failed or Phase.Timeout).ConfigureAwait(false);
        }
        if (states[id].Phase == Phase.Fatal) await RecordAsync("Fatal", id, before.RunId, states[id].Error ?? "Automatic retry stopped.", true).ConfigureAwait(false);
        // A queued handshake may have been cancelled before a process exists.
        if (states[id].Phase == Phase.Stopping && !runs.ContainsKey(id) && !preparing.Contains(id))
        {
            RemovePendingStart(id); // cancelled batch entries never launch; the rest keep their order
            await ApplyAsync(id, new(Signal.Cleaned, states[id].RunId, states[id].Generation)).ConfigureAwait(false);
        }
        foreach (var effect in transition.Effects)
        {
            switch (effect)
            {
                case Effect.Launch:
                    if (exiting) { states[id] = states[id] with { Phase = Phase.Stopped, RunId = null }; break; }
                    if (!config.Enabled) { states[id] = states[id] with { Phase = Phase.Stopped, RunId = null }; break; }
                    states[id] = states[id] with { ConfigVersion = config.Version };
                    runConfigs[id] = config; QueueLaunch(id); break;
                case Effect.Break:
                    if (runs.TryGetValue(id, out var run)) Track(BreakAsync(id, before.Generation, run));
                    // A stop received during prepare is applied when the suspended run returns.
                    break;
                case Effect.Terminate:
                    if (e.Signal is Signal.Force or Signal.Tick) await RecordAsync("ForcedStop", id, before.RunId, "Grace period was skipped or elapsed; terminating the entire Job.", true).ConfigureAwait(false);
                    if (runs.TryGetValue(id, out var kill)) BeginCleanup(id, before.Generation, kill, null, before.StopReason);
                    break;
            }
        }
        var durableState = states[id]; WriteLater(() => store.SaveRuntimeAsync(id, durableState));
    }
    private void Track(Task task) { workers.RemoveAll(t => t.IsCompleted); workers.Add(task); }
    private void QueueLaunch(Guid id)
    {
        pendingStarts.Enqueue((id, states[id].RunId!.Value)); DrainStarts();
    }
    private void RemovePendingStart(Guid id)
    {
        var kept = pendingStarts.Where(x => x.Id != id).ToArray();
        pendingStarts.Clear();
        foreach (var item in kept) pendingStarts.Enqueue(item);
    }
    private void DrainStarts()
    {
        while (startupSlots < 4 && pendingStarts.TryDequeue(out var item))
        {
            var id = item.Id;
            // Skip entries whose run was cancelled, replaced, or is already owned (e.g. inside the startSeconds gate).
            if (exiting || !states.TryGetValue(id, out var state)) continue;
            if (state.Phase != Phase.Starting || state.RunId != item.RunId || runs.ContainsKey(id) || preparing.Contains(id)) continue;
            startupSlots++; preparing.Add(id); Track(PrepareAsync(id, state, runConfigs[id]));
        }
    }
    private async Task PrepareAsync(Guid id, RuntimeState state, ProgramConfig config)
    {
        IProcessRun? native = null;
        try
        {
            var dir = Path.Combine(logRoot, config.Kind == ProgramKind.Service ? "programs" : "runs", config.Kind == ProgramKind.Service ? id.ToString("N") : state.RunId!.Value.ToString("N"), state.RunId!.Value.ToString("N"));
            // Commit before invoking any native process creation.
            await ExecuteStorageAsync(async () => { await store.SaveRuntimeAsync(id, state).ConfigureAwait(false); await store.BeginRunAsync(new(state.RunId.Value, id, state.Generation, config.Version, clock.Now.Utc, LogDirectory: dir)).ConfigureAwait(false); }).ConfigureAwait(false);
            native = await host.PrepareAsync(state.RunId.Value, config.Launch, dir, lost => Post(() => RecordAsync("LogIncomplete", id, state.RunId, $"Dropped bytes: {lost}", true)), lifetime.Token).ConfigureAwait(false);
            var prepared = native;
            await ExecuteStorageAsync(() => store.IdentifyRunAsync(prepared.Id, prepared.Pid, prepared.CreationTime)).ConfigureAwait(false);
            await Enqueue(async () =>
            {
                var current = states[id];
                if (current.RunId != state.RunId || current.Generation != state.Generation) { await prepared.DisposeAsync().ConfigureAwait(false); return; }
                if (runs.TryGetValue(id, out var existing) && existing.Id != prepared.Id)
                {
                    // Invariant violation: never replace a run the supervisor already owns.
                    await prepared.DisposeAsync().ConfigureAwait(false);
                    Diagnostic?.Invoke($"invariant violation: duplicate run for program {id}", new InvalidOperationException($"Run {prepared.Id} duplicates {existing.Id}."));
                    return;
                }
                runs[id] = prepared;
                if (current.Phase == Phase.Stopping) { BeginCleanup(id, state.Generation, prepared, null, current.StopReason); return; }
                await ApplyAsync(id, new(Signal.Prepared, state.RunId, state.Generation, Pid: prepared.Pid, CreationTime: prepared.CreationTime)).ConfigureAwait(false);
                try { await prepared.ActivateAsync(lifetime.Token).ConfigureAwait(false); }
                catch (Exception activation)
                {
                    // The actor already owns the run: clean it through the normal path so it ends as HostFailed.
                    BeginCleanup(id, state.Generation, prepared, null, EndReason.HostFailed, activation.Message);
                    return;
                }
                Track(ObserveExitAsync(id, state.Generation, prepared));
            }).ConfigureAwait(false);
            native = null; // actor owns it now
        }
        catch (Exception ex)
        {
            if (native is not null)
            {
                var failedRun = native;
                bool empty;
                string cleanupError = "Failed launch cleanup could not be confirmed.";
                try { empty = await failedRun.CleanAsync(CancellationToken.None).ConfigureAwait(false); }
                catch (Exception cleanupException) { empty = false; cleanupError = cleanupException.Message; }
                if (!empty)
                {
                    Post(async () =>
                    {
                        if (states[id].RunId != state.RunId || states[id].Generation != state.Generation) { await failedRun.DisposeAsync().ConfigureAwait(false); return; }
                        runs[id] = failedRun;
                        await ApplyAsync(id, new(Signal.CleanupFailed, state.RunId, state.Generation, Error: cleanupError)).ConfigureAwait(false);
                    });
                    return;
                }
                await failedRun.DisposeAsync().ConfigureAwait(false);
            }
            Post(async () => { if (states[id].RunId != state.RunId || states[id].Generation != state.Generation) return; if (runs.TryGetValue(id, out var owned) && owned.Id == state.RunId) runs.Remove(id); await ApplyAsync(id, new(Signal.SpawnFailed, state.RunId, state.Generation, Error: ex.Message)).ConfigureAwait(false); });
        }
        finally { Post(() => { startupSlots--; preparing.Remove(id); DrainStarts(); return Task.CompletedTask; }); }
    }
    private async Task ObserveExitAsync(Guid id, long generation, IProcessRun run)
    {
        uint? code = null; EndReason? reason = null; string? error = null;
        try { code = await run.Exit.ConfigureAwait(false); } catch (Exception ex) { reason = EndReason.HostFailed; error = ex.Message; }
        Post(() => { if (states.TryGetValue(id, out var current) && current.RunId == run.Id) BeginCleanup(id, generation, run, code, reason, error); return Task.CompletedTask; });
    }
    private async Task BreakAsync(Guid id, long generation, IProcessRun run)
    {
        try { await run.RequestBreakAsync(lifetime.Token).ConfigureAwait(false); }
        catch (Exception ex) { Post(() => { BeginCleanup(id, generation, run, null, EndReason.HostFailed, ex.Message); return Task.CompletedTask; }); }
    }
    private void BeginCleanup(Guid id, long generation, IProcessRun run, uint? code, EndReason? reason, string? error = null)
    {
        if (!states.TryGetValue(id, out var current) || current.RunId != run.Id || current.Generation != generation || !cleaning.Add(id)) return;
        states[id] = Reducer.Apply(current, new(Signal.CleanupStarted, run.Id, generation, ObservedActive: clock.Now.Active), runConfigs[id], clock.Now).State;
        var cleaningState = states[id]; WriteLater(() => store.SaveRuntimeAsync(id, cleaningState));
        Track(Task.Run(async () =>
        {
            bool empty;
            try { empty = await run.CleanAsync(CancellationToken.None).ConfigureAwait(false); if (empty) { if (run.Exit.IsCompletedSuccessfully) code ??= await run.Exit.ConfigureAwait(false); await run.DisposeAsync().ConfigureAwait(false); } }
            catch (Exception ex) { empty = false; error = ex.Message; }
            Post(async () =>
            {
                cleaning.Remove(id);
                await ApplyAsync(id, new(empty ? Signal.Cleaned : Signal.CleanupFailed, run.Id, generation, code, error ?? (empty ? null : "Process tree cleanup could not be confirmed; retry cleanup."), Reason: reason)).ConfigureAwait(false);
            });
        }));
    }
    private async Task TickAsync()
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(250));
            while (await timer.WaitForNextTickAsync(lifetime.Token).ConfigureAwait(false))
                if (Snapshot.Any(s => s.Runtime.Active || s.Runtime.Phase == Phase.Backoff) && Interlocked.Exchange(ref tickQueued, 1) == 0) Post(async () =>
                {
                    try { foreach (var id in states.Keys.ToArray()) await ApplyAsync(id, new(Signal.Tick)).ConfigureAwait(false); }
                    finally { Volatile.Write(ref tickQueued, 0); }
                });
        }
        catch (OperationCanceledException) { }
    }
    private void WriteLater(Func<Task> write) => storageQueue.Writer.TryWrite(write);
    private async Task ConsumeStorageAsync()
    {
        bool storageFaulted = false;
        await foreach (var write in storageQueue.Reader.ReadAllAsync())
        {
            try
            {
                await write().ConfigureAwait(false);
                // Storage recovered: the banner clears itself on the next successful write.
                if (storageFaulted) { storageFaulted = false; Post(() => { StorageError = null; return Task.CompletedTask; }); }
            }
            catch (Exception ex) { storageFaulted = true; Post(() => { StorageError = ex.Message; return Task.CompletedTask; }); }
        }
    }
    private Task ExecuteStorageAsync(Func<Task> write)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        WriteLater(async () => { try { await write().ConfigureAwait(false); completion.SetResult(); } catch (Exception ex) { completion.SetException(ex); throw; } });
        return completion.Task;
    }
    private async Task FlushWritesAsync()
    {
        await Enqueue(() => Task.CompletedTask).ConfigureAwait(false);
        await ExecuteStorageAsync(() => Task.CompletedTask).ConfigureAwait(false);
        await Enqueue(() => Task.CompletedTask).ConfigureAwait(false);
    }
    private async Task RecordAsync(string type, Guid? id, Guid? run, string detail, bool attention = false)
    {
        var record = new EventRecord(clock.Now.Utc, type, id, run, detail);
        WriteLater(() => store.EventAsync(record)); await Task.CompletedTask.ConfigureAwait(false); if (attention) Attention?.Invoke(record);
    }
    public async Task ShutdownAsync(TimeSpan budget, CancellationToken cancellationToken = default, Task? forceRequested = null, TimeSpan? forceBudget = null)
    {
        try
        {
            await Enqueue(async () =>
            {
                exiting = true; pendingStarts.Clear();
                foreach (var c in configs.Values.OrderByDescending(x => x.Priority).ThenBy(x => x.NameKey).ToArray())
                {
                    var s = states[c.Id];
                    if (!s.Active && s.Phase != Phase.Backoff) continue;
                    if (c.Kind == ProgramKind.Service && (s.Phase == Phase.Backoff || s.StopReason is null))
                    {
                        // Marked before the stop so the durable state of an interrupted exit still resumes next start.
                        s = s with { ResumeAfterAppExit = true }; states[c.Id] = s;
                        var marked = s; WriteLater(() => store.SaveRuntimeAsync(c.Id, marked));
                    }
                    await ApplyAsync(c.Id, new(Signal.Stop, Reason: EndReason.AppShutdown)).ConfigureAwait(false);
                }
            }).ConfigureAwait(false);
            var elapsed = System.Diagnostics.Stopwatch.StartNew();
            while (Snapshot.Any(s => s.Runtime.Active) && elapsed.Elapsed < budget && forceRequested?.IsCompleted != true) await Task.Delay(50, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            await Enqueue(async () => { foreach (var id in states.Keys.ToArray()) if (states[id].Active) await ApplyAsync(id, new(Signal.Force)).ConfigureAwait(false); }).ConfigureAwait(false);
            elapsed.Restart();
            while (Snapshot.Any(s => s.Runtime.Active) && elapsed.Elapsed < (forceBudget ?? TimeSpan.FromSeconds(5))) await Task.Delay(50, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (Snapshot.Any(s => s.Runtime.Active)) throw new InvalidOperationException("Cleanup is not confirmed; retry cleanup before exiting. Run records remain interrupted.");
            await FlushWritesAsync().ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (StorageError is null && !(await store.RunsAsync().ConfigureAwait(false)).Any(r => r.Ended is null)) await store.MarkCleanAsync().ConfigureAwait(false);
        }
        catch
        {
            await Enqueue(() =>
            {
                exiting = false;
                // A cancelled exit leaves stopped programs stopped; they must not resume on the next start.
                foreach (var id in states.Where(x => x.Value.ResumeAfterAppExit).Select(x => x.Key).ToArray())
                {
                    var cleared = states[id] with { ResumeAfterAppExit = false }; states[id] = cleared;
                    WriteLater(() => store.SaveRuntimeAsync(id, cleared));
                }
                return Task.CompletedTask;
            }).ConfigureAwait(false);
            throw;
        }
    }
    public async ValueTask DisposeAsync()
    {
        await Enqueue(() => { exiting = true; pendingStarts.Clear(); return Task.CompletedTask; }).ConfigureAwait(false);
        lifetime.Cancel(); await ticker.ConfigureAwait(false);
        // A run can still be registered by an in-flight prepare after the first sweep; keep sweeping until nothing is left,
        // otherwise its exit observer would wait forever on a run nobody disposes.
        var disposed = new HashSet<IProcessRun>();
        while (true)
        {
            IProcessRun[] fresh = []; Task[] pending = [];
            await Enqueue(() =>
            {
                fresh = runs.Values.Where(disposed.Add).ToArray();
                workers.RemoveAll(t => t.IsCompleted);
                pending = workers.ToArray();
                return Task.CompletedTask;
            }).ConfigureAwait(false);
            foreach (var run in fresh) await run.DisposeAsync().ConfigureAwait(false);
            if (fresh.Length == 0 && pending.Length == 0) break;
            await Task.WhenAll(pending).ConfigureAwait(false);
        }
        await FlushWritesAsync().ConfigureAwait(false);
        storageQueue.Writer.TryComplete(); await storageLoop.ConfigureAwait(false);
        queue.Writer.TryComplete(); await loop.ConfigureAwait(false);
        lifetime.Dispose();
    }
}
