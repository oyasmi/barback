using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
string Value(string key, string fallback = "") { var i = Array.IndexOf(args, key); return i >= 0 && i + 1 < args.Length ? args[i + 1] : fallback; }
int Number(string key, int fallback) => int.TryParse(Value(key), out var n) ? n : fallback;
var mode = Value("--mode", "hold"); var manifest = Value("--manifest");
if (manifest.Length > 0) await File.AppendAllTextAsync(manifest, $"{Environment.ProcessId} {Process.GetCurrentProcess().StartTime.ToFileTimeUtc()}\n");
if (mode == "echo") { Console.Write(JsonSerializer.Serialize(args.Skip(Array.IndexOf(args, "--mode") + 2).ToArray())); return; }
if (mode == "exit") { await Task.Delay(Number("--delay", 0)); Environment.Exit(unchecked((int)uint.Parse(Value("--code", "0")))); return; }
var stopping = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
Console.CancelKeyPress += (_, e) => { e.Cancel = true; if (Value("--ignore-break") != "true") stopping.TrySetResult(); };
if (mode == "tree")
{
    int depth = Number("--depth", 2);
    if (depth > 0)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
        foreach (var arg in new[] { "--mode", "tree", "--depth", (depth - 1).ToString(), "--manifest", manifest, "--ignore-break", "true" }) start.ArgumentList.Add(arg);
        using var child = Process.Start(start)!;
        if (Value("--root-exit") == "true") { await Task.Delay(300); return; }
    }
}
if (mode == "output")
{
    var chunks = Number("--chunks", 10000); var bytes = Encoding.UTF8.GetBytes(new string('中', 4096));
    using var stdout = Console.OpenStandardOutput(); using var stderr = Console.OpenStandardError();
    var a = Task.Run(async () => { for (int i = 0; i < chunks; i++) { await stdout.WriteAsync(bytes.AsMemory(0, 1)); await stdout.WriteAsync(bytes.AsMemory(1)); } });
    var b = Task.Run(async () => { for (int i = 0; i < chunks; i++) await stderr.WriteAsync(bytes); });
    await Task.WhenAll(a, b); return;
}
if (mode == "memory") { var memory = new byte[Number("--megabytes", 100) * 1024 * 1024]; for (int i = 0; i < memory.Length; i += 4096) memory[i] = 1; await stopping.Task; GC.KeepAlive(memory); return; }
await stopping.Task;
if (Value("--cleanup-file").Length > 0) await File.WriteAllTextAsync(Value("--cleanup-file"), "Ctrl+Break cleanup completed");
await Task.Delay(Number("--cleanup-delay", 0));
