using System.ComponentModel;
using System.IO.Pipes;
using System.Diagnostics;
using Barback.Core;
namespace Barback.Windows;

public sealed class WindowsProcessHost(string consoleHostPath, LogQuota? globalQuota = null) : IProcessHost
{
    private Dictionary<string, string> baseline = Native.UserEnvironment();
    private EnvironmentEntry[] applicationEnvironment = [];
    public void SetApplicationEnvironment(EnvironmentEntry[] entries) => applicationEnvironment = entries;
    public void RefreshEnvironment() => baseline = Native.UserEnvironment();
    /// <summary>Whole-boot tolerance for coarse clocks; a process created before this window cannot survive a reboot.</summary>
    private const long BootToleranceTicks = 60L * 10_000_000;
    /// <summary>True when a process created at <paramref name="creationTime"/> (FILETIME) must predate the current boot.</summary>
    public static bool PredatesBoot(long creationTime, long nowFileTime, ulong uptimeMilliseconds) =>
        creationTime < nowFileTime - (long)uptimeMilliseconds * 10_000 - BootToleranceTicks;
    public bool IsSameProcessAlive(int pid, long creationTime)
    {
        if (PredatesBoot(creationTime, DateTime.UtcNow.ToFileTimeUtc(), Native.GetTickCount64())) return false;
        using var p = Native.OpenProcess(0x101000, false, pid);
        if (p.IsInvalid)
        {
            // Barback only tracks processes it created as the current user, which that user can always open.
            // Not-found and access-denied therefore mean the PID was reused by someone else; anything else stays conservative.
            var error = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
            return error is not (87 or 5);
        }
        var wait = Native.WaitForSingleObject(p, 0);
        if (wait == 0) return false;
        if (wait != 258) return true;
        try { return Native.CreationTime(p) == creationTime; } catch (Win32Exception) { return true; }
    }
    public void EnsureCanLaunch()
    {
        if (applicationEnvironment.Any(e => e.NeedsInput)) throw new ApplicationEnvironmentNeedsInputException();
    }
    public async Task<IProcessRun> PrepareAsync(Guid runId, LaunchSpec launch, string logDirectory, Action<long> logLoss, CancellationToken token)
    {
        EnsureCanLaunch();
        var runQuota = new LogQuota(50L * 1024 * 1024);
        var job = Native.NewJob(); var collectors = new List<LogCollector>(); KernelHandle? process = null, thread = null, target = null; NamedPipeServerStream? pipe = null;
        (FileStream? Read, Microsoft.Win32.SafeHandles.SafeFileHandle? Write) stdout = default, stderr = default;
        Microsoft.Win32.SafeHandles.SafeFileHandle? input = null;
        try
        {
            var (outputRead, outputWrite) = Native.OutputPipe(); stdout = (outputRead, outputWrite);
            var (errorRead, errorWrite) = Native.OutputPipe(); stderr = (errorRead, errorWrite); input = Native.NullInput();
            collectors.Add(new(outputRead, Path.Combine(logDirectory, "stdout.log"), launch.LogSegmentBytes, launch.LogSegments, logLoss, globalQuota, runQuota));
            collectors.Add(new(errorRead, Path.Combine(logDirectory, "stderr.log"), launch.LogSegmentBytes, launch.LogSegments, logLoss, globalQuota, runQuota));
            var env = EnvironmentDraft.Merge(baseline, applicationEnvironment, launch.Environment);
            if (launch.StopMode == StopMode.TerminateJob)
            {
                var (exe, command) = WindowsCommandLine.Build(launch, Environment.SystemDirectory);
                var created = Native.Create(exe, command, launch.WorkingDirectory, env, job, input.DangerousGetHandle(), outputWrite.DangerousGetHandle(), errorWrite.DangerousGetHandle(), Native.NoWindow);
                process = created.Process; thread = created.Thread;
                return new WindowsRun(runId, job, process, thread, created.Pid, collectors, null, null);
            }
            if (!File.Exists(consoleHostPath)) throw new FileNotFoundException("ConsoleHost is missing. Reinstall Barback.");
            var pipeName = "barback-run-" + Guid.NewGuid().ToString("N");
            pipe = Native.LocalPipe(pipeName, PipeDirection.InOut);
            var hostCommand = WindowsCommandLine.Quote(consoleHostPath) + " " + pipeName + " " + Environment.ProcessId;
            var host = Native.Create(consoleHostPath, hostCommand, launch.WorkingDirectory, env, job, input.DangerousGetHandle(), outputWrite.DangerousGetHandle(), errorWrite.DangerousGetHandle(), Native.NewConsole);
            process = host.Process; thread = host.Thread;
            if (Native.ResumeThread(thread) == uint.MaxValue) throw new Win32Exception(); thread.Dispose(); thread = null;
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(10));
            await pipe.WaitForConnectionAsync(deadline.Token);
            Native.Check(Native.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var peer)); if (peer != host.Pid) throw new InvalidDataException("Unexpected host peer.");
            var protocol = new HostProtocol(pipe); await protocol.SendAsync(new("Launch", Launch: launch, Environment: env), deadline.Token);
            var ready = await protocol.ReadAsync(deadline.Token);
            if (ready.Type != "Ready" || ready.Pid is null || ready.CreationTime is null) throw new InvalidDataException("Host launch handshake failed.");
            target = Native.OpenProcess(0x101000, false, ready.Pid.Value);
            if (target.IsInvalid || Native.CreationTime(target) != ready.CreationTime.Value) { target.Dispose(); throw new InvalidDataException("Target identity could not be verified."); }
            return new WindowsRun(runId, job, target, null, ready.Pid.Value, collectors, pipe, protocol, process);
        }
        catch
        {
            Native.TerminateJobObject(job, 0xC000013A); thread?.Dispose(); target?.Dispose(); process?.Dispose(); pipe?.Dispose(); job.Dispose();
            stdout.Read?.Dispose(); stderr.Read?.Dispose(); foreach (var collector in collectors) await collector.DisposeAsync(); throw;
        }
        finally { input?.Dispose(); stdout.Write?.Dispose(); stderr.Write?.Dispose(); }
    }
    private sealed class WindowsRun : IProcessRun
    {
        private readonly KernelHandle job, process;
        private KernelHandle? thread;
        private readonly KernelHandle? host;
        private readonly NamedPipeServerStream? pipe;
        private readonly HostProtocol? protocol;
        private readonly List<LogCollector> collectors;
        private readonly CancellationTokenSource lifetime = new();
        private readonly TaskCompletionSource<uint> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly Task<uint> processExit;
        private Task? observe;
        private int disposed;
        public Guid Id { get; }
        public int Pid { get; }
        public long CreationTime { get; }
        public Task<uint> Exit => completion.Task;
        public WindowsRun(Guid id, KernelHandle job, KernelHandle process, KernelHandle? thread, int pid, List<LogCollector> collectors, NamedPipeServerStream? pipe, HostProtocol? protocol, KernelHandle? host = null)
        {
            Id = id; this.job = job; this.process = process; this.thread = thread; Pid = pid; this.collectors = collectors; this.pipe = pipe; this.protocol = protocol; this.host = host;
            CreationTime = Native.CreationTime(process); processExit = Native.WaitExitAsync(process);
        }
        public async Task ActivateAsync(CancellationToken token)
        {
            if (protocol is null) { if (thread is null || Native.ResumeThread(thread) == uint.MaxValue) throw new Win32Exception(); thread.Dispose(); thread = null; }
            else await protocol.SendAsync(new("Resume"), token);
            observe = ObserveAsync();
        }
        private async Task ObserveAsync()
        {
            try
            {
                if (protocol is null) { completion.TrySetResult(await processExit); return; }
                var message = await protocol.ReadAsync(lifetime.Token);
                if (message.Type != "Exited" || message.ExitCode is null) throw new InvalidDataException("Host exited without valid result.");
                var actual = await processExit;
                if (actual != message.ExitCode.Value) throw new InvalidDataException("Host exit identity mismatch.");
                completion.TrySetResult(actual);
            }
            catch (Exception ex) { completion.TrySetException(ex); }
        }
        public Task RequestBreakAsync(CancellationToken token) => protocol?.SendAsync(new("Break"), token) ?? Task.CompletedTask;
        public async Task<bool> CleanAsync(CancellationToken token)
        {
            Native.Check(Native.TerminateJobObject(job, 0xC000013A));
            var deadline = Stopwatch.GetTimestamp() + 5 * Stopwatch.Frequency;
            do { if (Native.ActiveProcesses(job) == 0) { completion.TrySetResult(await processExit); return true; } await Task.Delay(25, token); } while (Stopwatch.GetTimestamp() < deadline);
            return false;
        }
        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            lifetime.Cancel(); job.Dispose(); thread?.Dispose(); pipe?.Dispose();
            if (observe is not null) await observe;
            await processExit; process.Dispose();
            if (host is not null) { await Native.WaitExitAsync(host); host.Dispose(); }
            foreach (var collector in collectors) await collector.DisposeAsync(); lifetime.Dispose();
        }
    }
}
