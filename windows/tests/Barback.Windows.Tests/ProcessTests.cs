using Barback.Core;
using System.Diagnostics;
using System.Text.Json;
namespace Barback.Windows.Tests;

public sealed class WindowsFactAttribute : FactAttribute { public WindowsFactAttribute() { if (!OperatingSystem.IsWindows()) Skip = "Requires real Windows process APIs."; } }
public sealed class WindowsTheoryAttribute : TheoryAttribute { public WindowsTheoryAttribute() { if (!OperatingSystem.IsWindows()) Skip = "Requires real Windows process APIs."; } }
public sealed class ProcessTests
{
    private static string Child => Environment.GetEnvironmentVariable("BARBACK_TEST_CHILD_PATH") ?? throw new InvalidOperationException("Run scripts/test.ps1 to publish architecture-matched fixtures.");
    private static string ConsoleHost => Environment.GetEnvironmentVariable("BARBACK_CONSOLE_HOST_PATH") ?? throw new InvalidOperationException("Set BARBACK_CONSOLE_HOST_PATH.");
    private static string Temp() { var root = Path.Combine(Path.GetTempPath(), "barback-native-" + Guid.NewGuid()); Directory.CreateDirectory(root); return root; }
    private static LaunchSpec Spec(string[] args, StopMode mode = StopMode.TerminateJob) => new() { Executable = Child, Arguments = args, WorkingDirectory = Path.GetDirectoryName(Child)!, StopMode = mode };
    private static async Task AssertTreeExitedAsync(WindowsProcessHost host, IEnumerable<string> identities)
    {
        var processes = identities.Select(line => { var parts = line.Split(' '); return (Pid: int.Parse(parts[0]), Creation: long.Parse(parts[1])); }).ToArray();
        // Job termination and releasing descendant process objects do not complete at the same instant.
        // Wait for every identity, not just the root; unknown/access-denied results remain conservative.
        var deadline = Stopwatch.GetTimestamp() + 5 * Stopwatch.Frequency;
        while (processes.Any(p => host.IsSameProcessAlive(p.Pid, p.Creation)) && Stopwatch.GetTimestamp() < deadline) await Task.Delay(25);
        foreach (var p in processes) Assert.False(host.IsSameProcessAlive(p.Pid, p.Creation), $"Process {p.Pid} (creation {p.Creation}) did not exit within five seconds.");
    }
    [WindowsTheory]
    [InlineData(0u)]
    [InlineData(259u)]
    [InlineData(0xC000013Au)]
    [InlineData(uint.MaxValue)]
    public async Task DwordCodeUsesHandleSignaledState(uint code)
    {
        var root = Temp(); try
        {
            var host = new WindowsProcessHost(ConsoleHost); await using var run = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "exit", "--code", code.ToString()]), root, _ => { }, null, CancellationToken.None);
            Assert.True(host.IsSameProcessAlive(run.Pid, run.CreationTime)); await run.ActivateAsync(CancellationToken.None); Assert.Equal(code, await run.Exit.WaitAsync(TimeSpan.FromSeconds(15))); Assert.True(await run.CleanAsync(CancellationToken.None));
        }
        finally { Directory.Delete(root, true); }
    }
    [WindowsFact]
    public async Task UnicodeEmptyQuoteTrailingSlashAndMetacharArgumentsRoundTrip()
    {
        var root = Temp(); var expected = new[] { "", "中文 路径", "a\"b", "space " + '\\', "|", "%X%", "$x", ">" };
        try
        {
            await using (var run = await new WindowsProcessHost(ConsoleHost).PrepareAsync(Guid.NewGuid(), Spec(["--mode", "echo", .. expected]), root, _ => { }, null, CancellationToken.None)) { await run.ActivateAsync(CancellationToken.None); await run.Exit.WaitAsync(TimeSpan.FromSeconds(15)); Assert.True(await run.CleanAsync(CancellationToken.None)); }
            Assert.Equal(expected, JsonSerializer.Deserialize<string[]>(await File.ReadAllTextAsync(Path.Combine(root, "stdout.log"))));
        }
        finally { Directory.Delete(root, true); }
    }
    [WindowsFact]
    public async Task RootExitCleansAllRemainingDescendants()
    {
        var root = Temp(); var manifest = Path.Combine(root, "pids.txt");
        try
        {
            var host = new WindowsProcessHost(ConsoleHost); await using var run = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "tree", "--depth", "3", "--manifest", manifest, "--root-exit", "true"]), Path.Combine(root, "logs"), _ => { }, null, CancellationToken.None);
            await run.ActivateAsync(CancellationToken.None); await run.Exit.WaitAsync(TimeSpan.FromSeconds(15)); Assert.True(await run.CleanAsync(CancellationToken.None));
            var lines = File.ReadAllLines(manifest); Assert.True(lines.Length >= 2);
            await AssertTreeExitedAsync(host, lines);
        }
        finally { Directory.Delete(root, true); }
    }
    [WindowsFact]
    public async Task DirectedBreakOnlyStopsSelectedTargetAndJobHandlesIgnoredBreak()
    {
        var root = Temp(); var marker = Path.Combine(root, "cleaned.txt");
        try
        {
            var host = new WindowsProcessHost(ConsoleHost);
            await using var a = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "hold", "--cleanup-file", marker], StopMode.ConsoleBreakThenTerminate), Path.Combine(root, "a"), _ => { }, null, CancellationToken.None);
            await using var b = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "hold", "--ignore-break", "true"], StopMode.ConsoleBreakThenTerminate), Path.Combine(root, "b"), _ => { }, null, CancellationToken.None);
            await a.ActivateAsync(CancellationToken.None); await b.ActivateAsync(CancellationToken.None); await Task.Delay(500);
            await a.RequestBreakAsync(CancellationToken.None); Assert.Equal(0u, await a.Exit.WaitAsync(TimeSpan.FromSeconds(15))); Assert.True(File.Exists(marker)); Assert.False(b.Exit.IsCompleted);
            await b.RequestBreakAsync(CancellationToken.None); await Task.Delay(300); Assert.False(b.Exit.IsCompleted); Assert.True(await b.CleanAsync(CancellationToken.None)); Assert.True(await a.CleanAsync(CancellationToken.None));
        }
        finally { Directory.Delete(root, true); }
    }
    [WindowsFact]
    public async Task SimultaneousLargeStreamsDrainAndReachEof()
    {
        var root = Temp(); try
        {
            await using (var run = await new WindowsProcessHost(ConsoleHost).PrepareAsync(Guid.NewGuid(), Spec(["--mode", "output", "--chunks", "500"]), root, _ => { }, null, CancellationToken.None)) { await run.ActivateAsync(CancellationToken.None); Assert.Equal(0u, await run.Exit.WaitAsync(TimeSpan.FromSeconds(30))); Assert.True(await run.CleanAsync(CancellationToken.None)); }
            Assert.True(new FileInfo(Path.Combine(root, "stdout.log")).Length > 0); Assert.True(new FileInfo(Path.Combine(root, "stderr.log")).Length > 0);
        }
        finally { Directory.Delete(root, true); }
    }
    [WindowsTheory]
    [InlineData("suspend")]
    [InlineData("resume")]
    public async Task OwnerDeathAtSuspendedOrActiveStageKillsJob(string stage)
    {
        var harness = Environment.GetEnvironmentVariable("BARBACK_CRASH_HARNESS_PATH") ?? throw new InvalidOperationException("Set BARBACK_CRASH_HARNESS_PATH."); var root = Temp();
        try
        {
            var start = new ProcessStartInfo(harness) { UseShellExecute = false, RedirectStandardOutput = true };
            var manifest = Path.Combine(root, "pids.txt"); foreach (var arg in new[] { ConsoleHost, Child, manifest, Path.Combine(root, "logs"), stage }) start.ArgumentList.Add(arg);
            using var owner = Process.Start(start)!;
            try
            {
                var ready = await owner.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15)); Assert.StartsWith("READY ", ready); var fields = ready!.Split(' ');
                if (stage == "resume") await Task.Delay(700); owner.Kill(); await owner.WaitForExitAsync();
                var host = new WindowsProcessHost(ConsoleHost);
                await AssertTreeExitedAsync(host, new[] { $"{fields[1]} {fields[2]}" }.Concat(File.Exists(manifest) ? File.ReadAllLines(manifest) : []));
            }
            finally { if (!owner.HasExited) { owner.Kill(); await owner.WaitForExitAsync(); } }
        }
        finally { Directory.Delete(root, true); }
    }
    [WindowsFact] // F5
    public void ProcessIdentityDistinguishesReusedAndOwnedPids()
    {
        var host = new WindowsProcessHost(ConsoleHost); using var self = Process.GetCurrentProcess(); var creation = self.StartTime.ToFileTimeUtc();
        Assert.False(host.IsSameProcessAlive(4, creation), "System process (access denied for standard users) must not lock a program.");
        Assert.True(host.IsSameProcessAlive(self.Id, creation));
        Assert.False(host.IsSameProcessAlive(self.Id, creation + 10_000_000));
        Assert.False(host.IsSameProcessAlive(self.Id, 1), "Creation time before this boot cannot match.");
    }
    [WindowsFact] // F10
    public async Task TargetEnvironmentDoesNotLeakIntoConsoleHost()
    {
        var root = Temp();
        try
        {
            // A 2 MiB GC heap limit would stop a .NET host from starting; cmd itself is unaffected, so the value can only arrive via the Launch message.
            var spec = new LaunchSpec { Mode = ExecutionMode.Cmd, ScriptText = "echo %DOTNET_GCHeapHardLimit%", WorkingDirectory = root, StopMode = StopMode.ConsoleBreakThenTerminate, Environment = [new("DOTNET_GCHeapHardLimit", "0x200000")] };
            await using (var run = await new WindowsProcessHost(ConsoleHost).PrepareAsync(Guid.NewGuid(), spec, root, _ => { }, null, CancellationToken.None)) { await run.ActivateAsync(CancellationToken.None); Assert.Equal(0u, await run.Exit.WaitAsync(TimeSpan.FromSeconds(15))); Assert.True(await run.CleanAsync(CancellationToken.None)); }
            Assert.Contains("0x200000", await File.ReadAllTextAsync(Path.Combine(root, "stdout.log")));
        }
        finally { Directory.Delete(root, true); }
    }
    [WindowsFact] // F11
    public async Task SlowResumeAfterReadyDoesNotExpireTheHostHandshake()
    {
        var root = Temp();
        try
        {
            await using (var run = await new WindowsProcessHost(ConsoleHost).PrepareAsync(Guid.NewGuid(), Spec(["--mode", "exit", "--code", "7"], StopMode.ConsoleBreakThenTerminate), root, _ => { }, null, CancellationToken.None))
            {
                await Task.Delay(TimeSpan.FromSeconds(15)); // longer than the 10 s connect/launch deadline
                await run.ActivateAsync(CancellationToken.None); Assert.Equal(7u, await run.Exit.WaitAsync(TimeSpan.FromSeconds(15))); Assert.True(await run.CleanAsync(CancellationToken.None));
            }
        }
        finally { Directory.Delete(root, true); }
    }
}
