using Barback.Core;
using Barback.Windows;
if (args.Length != 5) return 2;
var host = new WindowsProcessHost(args[0]);
await using var run = await host.PrepareAsync(Guid.NewGuid(), new() { Executable = args[1], WorkingDirectory = Path.GetDirectoryName(args[1])!, Arguments = ["--mode", "tree", "--manifest", args[2]], StopMode = StopMode.TerminateJob }, args[3], _ => { }, null, CancellationToken.None);
if (args[4] == "resume") await run.ActivateAsync(CancellationToken.None);
Console.WriteLine($"READY {run.Pid} {run.CreationTime}"); Console.Out.Flush();
await Task.Delay(Timeout.Infinite); return 0;
