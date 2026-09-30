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
    [WindowsTheory]
    [InlineData(0u)]
    [InlineData(259u)]
    [InlineData(0xC000013Au)]
    [InlineData(uint.MaxValue)]
    public async Task DwordCodeUsesHandleSignaledState(uint code)
    {
        var root = Temp(); try
        {
            var host = new WindowsProcessHost(ConsoleHost); await using var run = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "exit", "--code", code.ToString()]), root, _ => { }, CancellationToken.None);
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
            await using (var run = await new WindowsProcessHost(ConsoleHost).PrepareAsync(Guid.NewGuid(), Spec(["--mode", "echo", .. expected]), root, _ => { }, CancellationToken.None)) { await run.ActivateAsync(CancellationToken.None); await run.Exit.WaitAsync(TimeSpan.FromSeconds(15)); Assert.True(await run.CleanAsync(CancellationToken.None)); }
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
            var host = new WindowsProcessHost(ConsoleHost); await using var run = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "tree", "--depth", "3", "--manifest", manifest, "--root-exit", "true"]), Path.Combine(root, "logs"), _ => { }, CancellationToken.None);
            await run.ActivateAsync(CancellationToken.None); await run.Exit.WaitAsync(TimeSpan.FromSeconds(15)); Assert.True(await run.CleanAsync(CancellationToken.None));
            var lines = File.ReadAllLines(manifest); Assert.True(lines.Length >= 2);
            foreach (var line in lines) { var parts = line.Split(' '); Assert.False(host.IsSameProcessAlive(int.Parse(parts[0]), long.Parse(parts[1]))); }
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
            await using var a = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "hold", "--cleanup-file", marker], StopMode.ConsoleBreakThenTerminate), Path.Combine(root, "a"), _ => { }, CancellationToken.None);
            await using var b = await host.PrepareAsync(Guid.NewGuid(), Spec(["--mode", "hold", "--ignore-break", "true"], StopMode.ConsoleBreakThenTerminate), Path.Combine(root, "b"), _ => { }, CancellationToken.None);
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
            await using (var run = await new WindowsProcessHost(ConsoleHost).PrepareAsync(Guid.NewGuid(), Spec(["--mode", "output", "--chunks", "500"]), root, _ => { }, CancellationToken.None)) { await run.ActivateAsync(CancellationToken.None); Assert.Equal(0u, await run.Exit.WaitAsync(TimeSpan.FromSeconds(30))); Assert.True(await run.CleanAsync(CancellationToken.None)); }
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
                var host = new WindowsProcessHost(ConsoleHost); var deadline = DateTime.UtcNow.AddSeconds(5);
                while (host.IsSameProcessAlive(int.Parse(fields[1]), long.Parse(fields[2])) && DateTime.UtcNow < deadline) await Task.Delay(25);
                Assert.False(host.IsSameProcessAlive(int.Parse(fields[1]), long.Parse(fields[2])));
                if (File.Exists(manifest)) foreach (var line in File.ReadAllLines(manifest)) { var parts = line.Split(' '); Assert.False(host.IsSameProcessAlive(int.Parse(parts[0]), long.Parse(parts[1]))); }
            }
            finally { if (!owner.HasExited) { owner.Kill(); await owner.WaitForExitAsync(); } }
        }
        finally { Directory.Delete(root, true); }
    }
}
