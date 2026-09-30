using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
namespace Barback.Windows;

public sealed class KernelHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public KernelHandle() : base(true) { }
    public KernelHandle(nint value, bool owns = true) : base(owns) => SetHandle(value);
    protected override bool ReleaseHandle() => Native.CloseHandle(handle);
}
public static class Native
{
    public const uint Suspended = 4, NewConsole = 0x10, NewGroup = 0x200, NoWindow = 0x08000000;
    private const uint ExtendedStartup = 0x80000, UnicodeEnvironment = 0x400;
    [StructLayout(LayoutKind.Sequential)] public struct SecurityAttributes { public int Length; public nint Descriptor; public int Inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct StartupInfo
    {
        public int Size; public nint Reserved, Desktop, Title; public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags; public ushort Show, ReservedSize; public nint ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct StartupInfoEx { public StartupInfo Info; public nint Attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public nint Process, Thread; public uint Pid, Tid; }
    [StructLayout(LayoutKind.Sequential)] public struct BasicLimits { public long ProcessTime, JobTime; public uint Flags; public nuint MinWorkingSet, MaxWorkingSet; public uint ActiveLimit; public nuint Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] public struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] public struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [StructLayout(LayoutKind.Sequential)] public struct Accounting { public long User, Kernel, PeriodUser, PeriodKernel; public uint Faults, TotalProcesses, ActiveProcesses, TerminatedProcesses; }
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern KernelHandle CreateJobObjectW(nint attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(KernelHandle job, int infoClass, ref ExtendedLimits info, int size);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryInformationJobObject(KernelHandle job, int infoClass, out Accounting info, int size, nint returnLength);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool TerminateJobObject(KernelHandle job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool InitializeProcThreadAttributeList(nint list, int count, uint flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool UpdateProcThreadAttribute(nint list, uint flags, nuint attribute, nint value, nuint size, nint previous, nint returned);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(nint list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcessW(string application, StringBuilder command, nint processAttributes, nint threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, nint environment, string directory, ref StartupInfoEx startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern uint ResumeThread(KernelHandle thread);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern uint WaitForSingleObject(KernelHandle handle, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetExitCodeProcess(KernelHandle process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetProcessTimes(KernelHandle process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern KernelHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreatePipe(out nint read, out nint write, ref SecurityAttributes attributes, uint size);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetHandleInformation(nint handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, ref SecurityAttributes attributes, uint creation, uint flags, nint template);
    [DllImport("kernel32.dll")] public static extern nint GetStdHandle(int id);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool GenerateConsoleCtrlEvent(uint type, uint group);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)] public static extern bool QueryUnbiasedInterruptTime(out ulong value);
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
    [DllImport("kernel32.dll")] public static extern nint GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(nint process, uint access, out KernelHandle token);
    [DllImport("userenv.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateEnvironmentBlock(out nint block, KernelHandle token, [MarshalAs(UnmanagedType.Bool)] bool inherit);
    [DllImport("userenv.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyEnvironmentBlock(nint block);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafePipeHandle CreateNamedPipeW(string name, uint openMode, uint pipeMode, uint maxInstances, uint outputSize, uint inputSize, uint timeout, ref SecurityAttributes attributes);
    public static NamedPipeServerStream LocalPipe(string name, PipeDirection direction)
    {
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        var acl = new RawSecurityDescriptor($"D:P(A;;GA;;;{sid})"); var bytes = new byte[acl.BinaryLength]; acl.GetBinaryForm(bytes, 0);
        var descriptor = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, descriptor, bytes.Length);
            var sa = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor, Inherit = 0 };
            var access = direction == PipeDirection.In ? 1u : direction == PipeDirection.Out ? 2u : 3u;
            var handle = CreateNamedPipeW(@"\\.\pipe\" + name, access | 0x40000000 | 0x00080000, 8, 1, 65536, 65536, 0, ref sa);
            if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
            try { return new NamedPipeServerStream(direction, true, false, handle); } catch { handle.Dispose(); throw; }
        }
        finally { Marshal.FreeHGlobal(descriptor); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdentityInfo
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileIdentityInfo info);
    public static (uint Volume, ulong Index) FileIdentity(SafeFileHandle file)
    {
        Check(GetFileInformationByHandle(file, out var info)); return (info.Volume, ((ulong)info.IndexHigh << 32) | info.IndexLow);
    }
    public static void Check(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static KernelHandle NewJob()
    {
        var job = CreateJobObjectW(0, null); if (job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { var limits = new ExtendedLimits { Basic = new() { Flags = 0x2000 } }; Check(SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimits>())); return job; }
        catch { job.Dispose(); throw; }
    }
    public static uint ActiveProcesses(KernelHandle job) { Check(QueryInformationJobObject(job, 1, out var info, Marshal.SizeOf<Accounting>(), 0)); return info.ActiveProcesses; }
    public static long CreationTime(KernelHandle process) { Check(GetProcessTimes(process, out var time, out _, out _, out _)); return time; }
    public static Dictionary<string, string> UserEnvironment()
    {
        Check(OpenProcessToken(GetCurrentProcess(), 0xA, out var token)); using (token)
        {
            Check(CreateEnvironmentBlock(out var block, token, false));
            try
            {
                var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); var current = block;
                while (true) { var entry = Marshal.PtrToStringUni(current)!; if (entry.Length == 0) break; current += (entry.Length + 1) * 2; int eq = entry.IndexOf('=', 1); if (eq > 0 && entry[0] != '=') result[entry[..eq]] = entry[(eq + 1)..]; }
                return result;
            }
            finally { DestroyEnvironmentBlock(block); }
        }
    }
    public static (FileStream Read, SafeFileHandle Write) OutputPipe()
    {
        var sa = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Inherit = 1 }; Check(CreatePipe(out var r, out var w, ref sa, 0));
        var read = new SafeFileHandle(r, true); var write = new SafeFileHandle(w, true);
        try { Check(SetHandleInformation(r, 1, 0)); return (new FileStream(read, FileAccess.Read, 16384, false), write); }
        catch { read.Dispose(); write.Dispose(); throw; }
    }
    public static SafeFileHandle NullInput()
    {
        var sa = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Inherit = 1 };
        var h = CreateFileW("NUL", 0x80000000, 3, ref sa, 3, 0, 0); if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error()); return h;
    }
    public static (KernelHandle Process, KernelHandle Thread, int Pid) Create(string exe, string command, string directory, Dictionary<string, string> environment, KernelHandle? job, nint input, nint output, nint error, uint flags)
    {
        nuint size = 0; InitializeProcThreadAttributeList(0, job is null ? 1 : 2, 0, ref size);
        var list = Marshal.AllocHGlobal(checked((int)size)); var handles = Marshal.AllocHGlobal(3 * nint.Size); var jobValue = Marshal.AllocHGlobal(nint.Size); nint env = 0; bool initialized = false;
        try
        {
            Check(InitializeProcThreadAttributeList(list, job is null ? 1 : 2, 0, ref size)); initialized = true;
            Marshal.WriteIntPtr(handles, 0, input); Marshal.WriteIntPtr(handles, nint.Size, output); Marshal.WriteIntPtr(handles, 2 * nint.Size, error);
            Check(UpdateProcThreadAttribute(list, 0, 0x20002, handles, (nuint)(3 * nint.Size), 0, 0));
            if (job is not null) { Marshal.WriteIntPtr(jobValue, job.DangerousGetHandle()); Check(UpdateProcThreadAttribute(list, 0, 0x2000D, jobValue, (nuint)nint.Size, 0, 0)); }
            var envText = string.Join('\0', environment.OrderBy(k => k.Key, StringComparer.OrdinalIgnoreCase).Select(k => $"{k.Key}={k.Value}")) + "\0\0";
            env = Marshal.StringToHGlobalUni(envText);
            var si = new StartupInfoEx { Info = new() { Size = Marshal.SizeOf<StartupInfoEx>(), Flags = 0x101, Show = 0, Input = input, Output = output, Error = error }, Attributes = list };
            Check(CreateProcessW(exe, new StringBuilder(command), 0, 0, true, flags | Suspended | ExtendedStartup | UnicodeEnvironment, env, directory, ref si, out var p));
            return (new(p.Process), new(p.Thread), (int)p.Pid);
        }
        finally { if (initialized) DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); Marshal.FreeHGlobal(handles); Marshal.FreeHGlobal(jobValue); if (env != 0) Marshal.FreeHGlobal(env); }
    }
    private sealed class ProcessWaitHandle : WaitHandle
    {
        public ProcessWaitHandle(nint handle) => SafeWaitHandle = new SafeWaitHandle(handle, false);
    }
    public static Task<uint> WaitExitAsync(KernelHandle process)
    {
        var tcs = new TaskCompletionSource<uint>(TaskCreationOptions.RunContinuationsAsynchronously);
        var wait = new ProcessWaitHandle(process.DangerousGetHandle());
        RegisteredWaitHandle? registration = null;
        registration = ThreadPool.RegisterWaitForSingleObject(wait, (_, _) =>
        {
            try { Check(GetExitCodeProcess(process, out var code)); tcs.TrySetResult(code); }
            catch (Exception ex) { tcs.TrySetException(ex); }
        }, null, Timeout.Infinite, true);
        _ = tcs.Task.ContinueWith(_ => { registration.Unregister(null); wait.Dispose(); }, TaskScheduler.Default);
        return tcs.Task;
    }
}
public sealed class WindowsClock : Barback.Core.IClock
{
    public Barback.Core.ClockReading Now { get { Native.Check(Native.QueryUnbiasedInterruptTime(out var active)); return new(active / 10000000d, Native.GetTickCount64() / 1000d, DateTimeOffset.UtcNow); } }
}
