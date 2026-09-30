using System.IO.Pipes;
using System.Security.Principal;
using System.Security.AccessControl;
using System.Diagnostics;
using Barback.Windows;
namespace Barback.App;

public sealed class SingleInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly string pipeName;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task? server;
    private bool disposed;
    public bool IsOwner { get; }
    public SingleInstance(bool packaged, Action activated)
    {
        var sid = WindowsIdentity.GetCurrent().User!;
        var name = "Barback-" + (packaged ? "Release-" : "Dev-") + sid.Value;
        pipeName = name;
        var security = new MutexSecurity(); security.SetAccessRuleProtection(true, false); security.AddAccessRule(new MutexAccessRule(sid, MutexRights.FullControl, AccessControlType.Allow));
        mutex = MutexAcl.Create(false, "Global\\" + name, out _, security);
        // Mutex acquisition and release remain on the UI thread.
        try { IsOwner = mutex.WaitOne(0); } catch (AbandonedMutexException) { IsOwner = true; }
        if (IsOwner) server = ListenAsync(activated);
    }
    private async Task ListenAsync(Action activated)
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                using var pipe = Native.LocalPipe(pipeName, PipeDirection.In);
                await pipe.WaitForConnectionAsync(lifetime.Token);
                Native.Check(Native.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid));
                using var peer = Process.GetProcessById((int)pid);
                if (peer.SessionId != Process.GetCurrentProcess().SessionId) continue;
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); timeout.CancelAfter(2000);
                var bytes = new byte[5]; await pipe.ReadExactlyAsync(bytes, timeout.Token);
                if (bytes.SequenceEqual(new byte[] { 1, 0, 0, 0, 1 })) activated();
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or ArgumentException or System.ComponentModel.Win32Exception) { }
        }
    }
    public async Task<bool> ActivateExistingAsync()
    {
        try { using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly); await pipe.ConnectAsync(2000); Native.Check(Native.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var pid)); using var peer = Process.GetProcessById((int)pid); if (peer.SessionId != Process.GetCurrentProcess().SessionId) return false; await pipe.WriteAsync(new byte[] { 1, 0, 0, 0, 1 }); return true; }
        catch (Exception ex) when (ex is IOException or TimeoutException or ArgumentException) { return false; }
    }
    public void Dispose() { if (disposed) return; disposed = true; lifetime.Cancel(); if (IsOwner) mutex.ReleaseMutex(); mutex.Dispose(); lifetime.Dispose(); }
}
