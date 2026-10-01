using Barback.Core;
namespace Barback.Core.Tests;

public class SupervisorTests
{
    private sealed class Clock : IClock { public ClockReading Now => new(10, 10, DateTimeOffset.UtcNow); }
    private sealed class Store : IStore
    {
        public List<ProgramConfig> Configs = []; private readonly System.Collections.Concurrent.ConcurrentDictionary<Guid, RunRecord> records = []; public RunRecord[] Runs => records.Values.ToArray(); public Dictionary<Guid, RuntimeState> Runtime = [];
        public bool FailWrites; public bool FailIdentify; public bool Interrupted; public TaskCompletionSource? SaveHold; public bool SaveEntered;
        public Task<IReadOnlyList<ProgramConfig>> LoadProgramsAsync() => Task.FromResult<IReadOnlyList<ProgramConfig>>(Configs.ToArray());
        public async Task<ProgramConfig> SaveAsync(ProgramConfig c, long expected) { SaveEntered = true; if (SaveHold is not null) await SaveHold.Task; if (FailWrites) throw new IOException("disk full"); var current = Configs.SingleOrDefault(x => x.Id == c.Id); if ((current?.Version ?? 0) != expected) throw new IOException("conflict"); var next = c with { Version = expected + 1 }; Configs.RemoveAll(x => x.Id == c.Id); Configs.Add(next); return next; }
        public Task<IReadOnlyList<ProgramConfig>> ImportAsync(IReadOnlyList<ProgramConfig> drafts) { var items = drafts.Select(c => c with { Version = 1 }).ToArray(); Configs.AddRange(items); return Task.FromResult<IReadOnlyList<ProgramConfig>>(items); }
        public Task DeleteAsync(Guid id) { Configs.RemoveAll(x => x.Id == id); return Task.CompletedTask; }
        public Task BeginRunAsync(RunRecord run) { if (FailWrites) throw new IOException("disk full"); records[run.Id] = run; return Task.CompletedTask; }
        public Task IdentifyRunAsync(Guid id, int pid, long time) { if (FailWrites || FailIdentify) throw new IOException("disk full"); records[id] = records[id] with { Pid = pid, CreationTime = time }; return Task.CompletedTask; }
        public Task EndRunAsync(Guid id, Phase phase, EndReason reason, uint? code) { if (FailWrites) throw new IOException("disk full"); if (records.TryGetValue(id, out var run) && run.Ended is null) records[id] = run with { Ended = DateTimeOffset.UtcNow, Outcome = phase, Reason = reason, ExitCode = code }; return Task.CompletedTask; }
        public Task SaveRuntimeAsync(Guid id, RuntimeState runtime) { if (FailWrites) throw new IOException("disk full"); Runtime[id] = runtime; return Task.CompletedTask; }
        public Task<IReadOnlyDictionary<Guid, RuntimeState>> LoadRuntimeAsync() => Task.FromResult<IReadOnlyDictionary<Guid, RuntimeState>>(new Dictionary<Guid, RuntimeState>(Runtime));
        public Task<IReadOnlyList<RunRecord>> RunsAsync() => Task.FromResult<IReadOnlyList<RunRecord>>(Runs.ToArray());
        public Task<IReadOnlyList<EventRecord>> EventsAsync() => Task.FromResult<IReadOnlyList<EventRecord>>([]);
        public Task EventAsync(EventRecord r) => Task.CompletedTask;
        public Task<bool> RecoverAsync() => Task.FromResult(Interrupted);
        public Task MarkCleanAsync() => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class Run(Guid id) : IProcessRun
    {
        public Guid Id => id; public int Pid => 42; public long CreationTime => 100;
        public readonly TaskCompletionSource<uint> End = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<uint> Exit => End.Task; public bool Activated, Cleaned, Disposed;
        public int CleanupFailures;
        public Task ActivateAsync(CancellationToken token) { Activated = true; return Task.CompletedTask; }
        public Task RequestBreakAsync(CancellationToken token) => Task.CompletedTask;
        public Task<bool> CleanAsync(CancellationToken token) { if (CleanupFailures-- > 0) throw new IOException("cleanup unavailable"); Cleaned = true; End.TrySetResult(0xC000013A); return Task.FromResult(true); }
        public ValueTask DisposeAsync() { Disposed = true; End.TrySetResult(0xC000013A); return ValueTask.CompletedTask; }
    }
    private sealed class Host(Store store) : IProcessHost
    {
        private readonly System.Collections.Concurrent.ConcurrentQueue<Run> created = []; public Run[] Runs => created.ToArray();
        public TaskCompletionSource? Hold;
        public int CleanupFailures;
        public async Task<IProcessRun> PrepareAsync(Guid id, LaunchSpec launch, string path, Action<long> loss, CancellationToken token)
        {
            Assert.Contains(store.Runs, r => r.Id == id); var run = new Run(id) { CleanupFailures = CleanupFailures }; created.Enqueue(run); if (Hold is not null) await Hold.Task.WaitAsync(token); return run;
        }
        public bool IsSameProcessAlive(int pid, long time) => false;
    }
    private static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5); while (!condition()) { if (DateTime.UtcNow > deadline) throw new TimeoutException(); await Task.Delay(10); }
    }
    private static ProgramConfig Config(string root, ProgramKind kind = ProgramKind.Service) => new() { Name = "test", Kind = kind, Launch = new() { Executable = Path.Combine(root, "fixture.exe"), WorkingDirectory = root, StopMode = StopMode.TerminateJob }, Policy = new() { Autostart = false, StartSeconds = 0, Restart = RestartPolicy.Never } };
    private static string Temp() { var root = Path.Combine(Path.GetTempPath(), "barback-actor-" + Guid.NewGuid()); Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "fixture.exe"), ""); return root; }
    [Fact]
    public async Task PublishedRunConfigurationRemainsOriginalAfterEditing()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root); store.Configs.Add(config); var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root);
            await supervisor.InitializeAsync(); await supervisor.SendAsync(config.Id, Signal.Start);
            await Until(() => host.Runs.Any(r => r.Activated));
            await supervisor.SaveAsync(config with { Name = "renamed", Launch = config.Launch with { EncodingCodePage = 1200 } }, 0);
            var snapshot = supervisor.Snapshot.Single();
            Assert.Equal(1200, snapshot.Config.Launch.EncodingCodePage);
            Assert.Equal(65001, snapshot.RunConfig!.Launch.EncodingCodePage);
            Assert.Equal("test", snapshot.RunConfig.Name);
            await supervisor.SendAsync(config.Id, Signal.Force);
            await Until(() => !supervisor.Snapshot.Single().Runtime.Active);
            Assert.Null(supervisor.Snapshot.Single().RunConfig);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task FailedIdentityCommitAndCleanupExceptionRetainOwnershipForRetry()
    {
        var root = Temp(); try
        {
            var store = new Store { FailIdentify = true }; var config = Config(root); store.Configs.Add(config); var host = new Host(store) { CleanupFailures = 1 };
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); await supervisor.SendAsync(config.Id, Signal.Start);
            await Until(() => supervisor.Snapshot.Single().Runtime.CleanupFailed);
            Assert.False(host.Runs[0].Activated); Assert.False(host.Runs[0].Disposed);
            await supervisor.SendAsync(config.Id, Signal.Force); await Until(() => supervisor.Snapshot.Single().Runtime.Phase == Phase.Stopped);
            Assert.True(host.Runs[0].Cleaned); Assert.True(host.Runs[0].Disposed);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task CancelExitKeepsStoppedIntentAndAllowsNewExplicitStarts()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root); config = config with { Launch = config.Launch with { StopMode = StopMode.ConsoleBreakThenTerminate, StopWaitSeconds = 30 } };
            var other = Config(root) with { Name = "other" }; store.Configs.AddRange([config, other]); var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); await supervisor.SendAsync(config.Id, Signal.Start); await Until(() => host.Runs.Any(r => r.Activated));
            using var cancellation = new CancellationTokenSource(); var shutdown = supervisor.ShutdownAsync(TimeSpan.FromSeconds(25), cancellation.Token);
            await Until(() => supervisor.Snapshot.Single(s => s.Config.Id == config.Id).Runtime.Phase == Phase.Stopping);
            cancellation.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => shutdown);
            Assert.False(host.Runs[0].Cleaned); Assert.Single(host.Runs);
            await supervisor.SendAsync(other.Id, Signal.Start); await Until(() => host.Runs.Length == 2 && host.Runs[1].Activated);
            await supervisor.SendAsync(config.Id, Signal.Force); await supervisor.SendAsync(other.Id, Signal.Force);
            await Until(() => supervisor.Snapshot.All(s => !s.Runtime.Active));
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task ExplicitForceExitBypassesGraceAndWaitsForCleanup()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root); config = config with { Launch = config.Launch with { StopMode = StopMode.ConsoleBreakThenTerminate, StopWaitSeconds = 30 } }; store.Configs.Add(config); var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); await supervisor.SendAsync(config.Id, Signal.Start); await Until(() => host.Runs.Any(r => r.Activated));
            var force = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var shutdown = supervisor.ShutdownAsync(TimeSpan.FromSeconds(25), forceRequested: force.Task);
            await Until(() => supervisor.Snapshot.Single().Runtime.Phase == Phase.Stopping); force.SetResult();
            await shutdown.WaitAsync(TimeSpan.FromSeconds(2)); Assert.True(host.Runs[0].Cleaned); Assert.True(host.Runs[0].Disposed); Assert.Equal(Phase.Stopped, supervisor.Snapshot.Single().Runtime.Phase);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task StopDuringPrepareNeverResumesTarget()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root); store.Configs.Add(config); var host = new Host(store) { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) };
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); await supervisor.SendAsync(config.Id, Signal.Start); await Until(() => host.Runs.Length == 1);
            await supervisor.SendAsync(config.Id, Signal.Stop); host.Hold.SetResult(); await Until(() => supervisor.Snapshot.Single().Runtime.Phase == Phase.Stopped);
            Assert.False(host.Runs[0].Activated); Assert.True(host.Runs[0].Cleaned); Assert.True(host.Runs[0].Disposed); await Until(() => store.Runs.Single().Ended is not null); Assert.Equal(EndReason.UserStop, store.Runs.Single().Reason);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task DuplicateOneShotStartReturnsSameRunAndStopWorksWhenStoreFails()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root, ProgramKind.Oneshot); store.Configs.Add(config); var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync();
            await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => supervisor.SendAsync(config.Id, Signal.Start))); await Until(() => host.Runs.Any(r => r.Activated)); Assert.Single(host.Runs); Assert.Single(store.Runs);
            store.FailWrites = true; await supervisor.SendAsync(config.Id, Signal.Stop); await Until(() => supervisor.Snapshot.Single().Runtime.Phase == Phase.Cancelled); Assert.True(host.Runs[0].Cleaned); await Until(() => supervisor.StorageError is not null);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task FailedSaveDoesNotStopActiveRunAndSuccessfulRestartUsesNewestVersion()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root) with { Version = 1 }; store.Configs.Add(config); var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); await supervisor.SendAsync(config.Id, Signal.Start); await Until(() => host.Runs.Any(r => r.Activated));
            store.FailWrites = true; await Assert.ThrowsAsync<IOException>(() => supervisor.SaveAsync(config with { Name = "changed" }, 1)); Assert.False(host.Runs[0].Cleaned);
            store.FailWrites = false; await supervisor.SaveAsync(config with { Name = "changed" }, 1); await supervisor.SendAsync(config.Id, Signal.Restart); await Until(() => host.Runs.Length == 2 && host.Runs[1].Activated);
            Assert.True(host.Runs[0].Cleaned); Assert.Equal(2, supervisor.Snapshot.Single().Runtime.ConfigVersion); await supervisor.ShutdownAsync(TimeSpan.FromSeconds(1));
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task CancelBatchBeforeQueuedHandshakesStart()
    {
        var root = Temp(); try
        {
            var store = new Store(); for (int i = 0; i < 7; i++) store.Configs.Add(Config(root) with { Name = "test" + i }); var host = new Host(store) { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) };
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); await supervisor.BatchAsync(Signal.Start); await Until(() => host.Runs.Length == 4);
            await supervisor.BatchAsync(Signal.Stop); host.Hold.SetResult(); await Until(() => supervisor.Snapshot.All(x => !x.Runtime.Active)); Assert.Equal(4, host.Runs.Length); Assert.All(host.Runs, r => Assert.False(r.Activated));
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task BlockedConfigurationSaveDoesNotBlockStop()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root); store.Configs.Add(config); var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); await supervisor.SendAsync(config.Id, Signal.Start); await Until(() => host.Runs.Any(r => r.Activated));
            store.SaveHold = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var saving = supervisor.SaveAsync(config with { Name = "new" }, 0); await Until(() => store.SaveEntered);
            await supervisor.SendAsync(config.Id, Signal.Stop).WaitAsync(TimeSpan.FromMilliseconds(500)); await Until(() => host.Runs[0].Cleaned);
            Assert.False(saving.IsCompleted); store.SaveHold.SetResult(); await saving;
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task CrashRecoveryDoesNotResetFatalOrRerunOneShot()
    {
        var root = Temp(); try
        {
            var store = new Store { Interrupted = true }; var service = Config(root) with { Policy = new() { Autostart = true } }; var oneshot = Config(root, ProgramKind.Oneshot); store.Configs.AddRange([service, oneshot]);
            store.Runtime[service.Id] = new() { Phase = Phase.Fatal, Error = "storm" }; store.Runtime[oneshot.Id] = new() { Phase = Phase.Running, RunId = Guid.NewGuid() }; var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync(); Assert.Empty(host.Runs); Assert.Equal(Phase.Fatal, supervisor.Snapshot.Single(x => x.Config.Id == service.Id).Runtime.Phase); Assert.Equal(Phase.Interrupted, supervisor.Snapshot.Single(x => x.Config.Id == oneshot.Id).Runtime.Phase);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact] // F1
    public async Task StoppingQueuedStartDoesNotRelaunchProgramInStartGate()
    {
        var root = Temp(); try
        {
            var store = new Store();
            var a = Config(root) with { Name = "a", Policy = new() { Autostart = false, StartSeconds = 5, Restart = RestartPolicy.Never } };
            var held = Enumerable.Range(0, 4).Select(i => Config(root) with { Name = "held" + i }).ToArray();
            var queued = Config(root) with { Name = "queued" };
            store.Configs.Add(a); store.Configs.AddRange(held); store.Configs.Add(queued);
            var host = new Host(store);
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync();
            await supervisor.SendAsync(a.Id, Signal.Start); await Until(() => host.Runs.Length == 1 && host.Runs[0].Activated);
            Assert.Equal(Phase.Starting, supervisor.Snapshot.Single(s => s.Config.Id == a.Id).Runtime.Phase); // inside startSeconds gate
            host.Hold = new(TaskCreationOptions.RunContinuationsAsynchronously);
            foreach (var h in held) await supervisor.SendAsync(h.Id, Signal.Start); // occupy all four startup slots
            await Until(() => host.Runs.Length == 5);
            await supervisor.SendAsync(queued.Id, Signal.Start);
            await supervisor.SendAsync(queued.Id, Signal.Stop);
            host.Hold.SetResult();
            await Task.Delay(1000);
            var aRun = supervisor.Snapshot.Single(s => s.Config.Id == a.Id).Runtime.RunId;
            var count = host.Runs.Count(r => r.Id == aRun);
            foreach (var r in host.Runs) await r.DisposeAsync(); // unblock orphaned observers before the supervisor is disposed
            Assert.Equal(1, count);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F4
    public async Task InvalidStartDoesNotSetStorageError()
    {
        var root = Temp(); try
        {
            var store = new Store(); var config = Config(root) with { Launch = new() { Executable = Path.Combine(root, "missing.exe"), WorkingDirectory = root } }; store.Configs.Add(config);
            await using var supervisor = new Supervisor(store, new Host(store), new Clock(), root); await supervisor.InitializeAsync();
            await Assert.ThrowsAsync<ArgumentException>(() => supervisor.SendAsync(config.Id, Signal.Start));
            Assert.Null(supervisor.StorageError);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F3
    public async Task CleanExitKeepsFatal()
    {
        var root = Temp(); try
        {
            var store = new Store(); var service = Config(root) with { Policy = new() { Autostart = true } }; store.Configs.Add(service);
            store.Runtime[service.Id] = new() { Phase = Phase.Fatal, Error = "Startup retries exhausted." }; var host = new Host(store);
            await using (var supervisor = new Supervisor(store, host, new Clock(), root)) { await supervisor.InitializeAsync(); await supervisor.ShutdownAsync(TimeSpan.FromSeconds(1)); }
            await using var next = new Supervisor(store, host, new Clock(), root); await next.InitializeAsync();
            Assert.Empty(host.Runs);
            Assert.Equal(Phase.Fatal, next.Snapshot.Single().Runtime.Phase);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F2
    public async Task ShutdownStopInterruptedBeforeMarkCleanStillAutostartsNextBoot()
    {
        var root = Temp(); try
        {
            var store = new Store(); var service = Config(root) with { Policy = new() { Autostart = true, StartSeconds = 0, Restart = RestartPolicy.Never } }; store.Configs.Add(service);
            var host = new Host(store);
            await using (var supervisor = new Supervisor(store, host, new Clock(), root))
            {
                await supervisor.InitializeAsync(); await Until(() => host.Runs.Any(r => r.Activated));
                await supervisor.ShutdownAsync(TimeSpan.FromSeconds(1)); // persisted runtime equals what a session-end stop leaves behind
            }
            store.Interrupted = true; // MarkClean never became durable (process ended during WM_ENDSESSION)
            await using var next = new Supervisor(store, host, new Clock(), root); await next.InitializeAsync();
            await Until(() => host.Runs.Length == 2);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F1
    public async Task CancellingOneQueuedStartStartsExactlyTheRemainingPrograms()
    {
        var root = Temp(); try
        {
            var store = new Store(); var configs = Enumerable.Range(0, 7).Select(i => Config(root) with { Name = "p" + i, Priority = 10 + i }).ToArray(); store.Configs.AddRange(configs);
            var host = new Host(store) { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) };
            await using var supervisor = new Supervisor(store, host, new Clock(), root); await supervisor.InitializeAsync();
            await supervisor.BatchAsync(Signal.Start); await Until(() => host.Runs.Length == 4);
            await supervisor.SendAsync(configs[5].Id, Signal.Stop); // queued, never prepared
            host.Hold.SetResult(); await Until(() => host.Runs.Length == 6 && host.Runs.All(r => r.Activated));
            await Task.Delay(200);
            var programs = host.Runs.Select(r => store.Runs.Single(x => x.Id == r.Id).ProgramId).ToArray();
            Assert.Equal(6, programs.Length); Assert.Equal(6, programs.Distinct().Count()); Assert.DoesNotContain(configs[5].Id, programs);
            Assert.Equal(configs.Take(4).Select(c => c.Id).Order(), programs.Take(4).Order());
            Assert.Equal(new[] { configs[4].Id, configs[6].Id }.Order(), programs.Skip(4).Order()); // later starts race for freed slots; only membership is deterministic
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F2
    public async Task AppShutdownStopIsRecordedAsAppShutdownAndMarksResume()
    {
        var root = Temp(); try
        {
            var store = new Store(); var service = Config(root) with { Policy = new() { Autostart = true, StartSeconds = 0, Restart = RestartPolicy.Never } }; store.Configs.Add(service); var host = new Host(store);
            await using (var supervisor = new Supervisor(store, host, new Clock(), root)) { await supervisor.InitializeAsync(); await Until(() => host.Runs.Any(r => r.Activated)); await supervisor.ShutdownAsync(TimeSpan.FromSeconds(1)); }
            Assert.Equal(EndReason.AppShutdown, store.Runs.Single().Reason); Assert.True(store.Runtime[service.Id].ResumeAfterAppExit);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F2
    public async Task ServiceInBackoffAtExitResumesAfterInterruptedShutdown()
    {
        var root = Temp(); try
        {
            var store = new Store(); var service = Config(root) with { Policy = new() { Autostart = true, StartSeconds = 0, Restart = RestartPolicy.Unexpected } }; store.Configs.Add(service); var host = new Host(store);
            await using (var supervisor = new Supervisor(store, host, new Clock(), root))
            {
                await supervisor.InitializeAsync(); await Until(() => host.Runs.Any(r => r.Activated));
                host.Runs[0].End.TrySetResult(1); await Until(() => supervisor.Snapshot.Single().Runtime.Phase == Phase.Backoff);
                await supervisor.ShutdownAsync(TimeSpan.FromSeconds(1));
            }
            store.Interrupted = true;
            await using var next = new Supervisor(store, host, new Clock(), root); await next.InitializeAsync();
            await Until(() => host.Runs.Length == 2);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F2
    public async Task ManuallyStoppedServiceIsNotResumedAfterInterruptedShutdown()
    {
        var root = Temp(); try
        {
            var store = new Store(); var service = Config(root) with { Policy = new() { Autostart = true, StartSeconds = 0, Restart = RestartPolicy.Never } }; store.Configs.Add(service); var host = new Host(store);
            await using (var supervisor = new Supervisor(store, host, new Clock(), root))
            {
                await supervisor.InitializeAsync(); await Until(() => host.Runs.Any(r => r.Activated));
                await supervisor.SendAsync(service.Id, Signal.Stop); await Until(() => supervisor.Snapshot.Single().Runtime.Phase == Phase.Stopped);
            }
            store.Interrupted = true;
            await using var next = new Supervisor(store, host, new Clock(), root); await next.InitializeAsync();
            await Task.Delay(300); Assert.Single(host.Runs); Assert.Equal(Phase.Stopped, next.Snapshot.Single().Runtime.Phase);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact] // F2
    public async Task CancelledExitClearsResumeMarker()
    {
        var root = Temp(); try
        {
            var store = new Store(); var service = Config(root) with { Launch = Config(root).Launch with { StopMode = StopMode.ConsoleBreakThenTerminate, StopWaitSeconds = 30 }, Policy = new() { Autostart = true, StartSeconds = 0, Restart = RestartPolicy.Never } }; store.Configs.Add(service); var host = new Host(store);
            await using (var supervisor = new Supervisor(store, host, new Clock(), root))
            {
                await supervisor.InitializeAsync(); await Until(() => host.Runs.Any(r => r.Activated));
                using var cancellation = new CancellationTokenSource(); var shutdown = supervisor.ShutdownAsync(TimeSpan.FromSeconds(25), cancellation.Token);
                await Until(() => supervisor.Snapshot.Single().Runtime.Phase == Phase.Stopping); cancellation.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => shutdown);
            }
            Assert.False(store.Runtime[service.Id].ResumeAfterAppExit);
            store.Interrupted = true;
            await using var next = new Supervisor(store, host, new Clock(), root); await next.InitializeAsync();
            await Task.Delay(300); Assert.Single(host.Runs);
        }
        finally { Directory.Delete(root, true); }
    }
}
