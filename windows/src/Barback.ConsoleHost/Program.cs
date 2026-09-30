using System.IO.Pipes;
using Barback.Core;
using Barback.Windows;
// No configuration, persistent state, logging, restart logic, or Job handles live here.
if (args.Length != 2 || !int.TryParse(args[1], out var owner)) return 2;
try
{
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    using var pipe = new NamedPipeClientStream(".", args[0], PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    await pipe.ConnectAsync(deadline.Token);
    Native.Check(Native.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var peer)); if (peer != owner) return 3;
    var protocol = new HostProtocol(pipe); var launch = await protocol.ReadAsync(deadline.Token);
    if (launch.Type != "Launch" || launch.Launch is null || launch.Environment is null) return 4;
    var s = launch.Launch; var (exe, command) = WindowsCommandLine.Build(s, Environment.SystemDirectory);
    nint input = Native.GetStdHandle(-10), output = Native.GetStdHandle(-11), error = Native.GetStdHandle(-12);
    Native.Check(Native.SetHandleInformation(input, 1, 1)); Native.Check(Native.SetHandleInformation(output, 1, 1)); Native.Check(Native.SetHandleInformation(error, 1, 1));
    var target = Native.Create(exe, command, s.WorkingDirectory, launch.Environment, null, input, output, error, Native.NewGroup);
    using var process = target.Process; using var thread = target.Thread;
    await protocol.SendAsync(new("Ready", Pid: target.Pid, CreationTime: Native.CreationTime(process)), deadline.Token);
    var resume = await protocol.ReadAsync(deadline.Token); if (resume.Type != "Resume") return 5;
    if (Native.ResumeThread(thread) == uint.MaxValue) return 6;
    using var reading = new CancellationTokenSource();
    var exited = Native.WaitExitAsync(process);
    var next = protocol.ReadAsync(reading.Token);
    while (true)
    {
        if (await Task.WhenAny(exited, next) == exited)
        {
            await protocol.SendAsync(new("Exited", ExitCode: await exited), CancellationToken.None); reading.Cancel();
            try { await next; } catch (OperationCanceledException) { }
            return 0;
        }
        var message = await next; if (message.Type != "Break") return 7;
        Native.Check(Native.GenerateConsoleCtrlEvent(1, (uint)target.Pid));
        next = protocol.ReadAsync(reading.Token);
    }
}
catch { return 8; } // App observes EOF and kills the entire Job; no secret-bearing error output.
