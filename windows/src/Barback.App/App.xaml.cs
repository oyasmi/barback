using System.Security.Principal;
using System.Globalization;
using Barback.Core;
using Barback.Storage;
using Barback.Windows;
namespace Barback.App;

public partial class App : Application
{
    private SingleInstance? instance;
    private ShellIntegration? shell;
    private SqliteStore? store;
    private Supervisor? supervisor;
    private TrayAdapter? tray;
    private bool exiting;
    private bool pendingActivation;
    public bool IsExiting => exiting;
    public bool CloseExits { get; set; }
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Match the Windows API baseline and MSIX MinVersion (Windows 10 2004).
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) { MessageBox.Show("Barback requires Windows 10 version 2004 (build 19041) or later.", "Barback"); Shutdown(1); return; }
        DispatcherUnhandledException += (_, args) => { MessageBox.Show(args.Exception.Message, "Barback", MessageBoxButton.OK, MessageBoxImage.Error); args.Handled = true; };
        using var identity = WindowsIdentity.GetCurrent();
        if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) { MessageBox.Show("Barback must run as a standard user. Close it and launch without administrator privileges.", "Barback"); Shutdown(1); return; }
        shell = new();
        Guid? notificationProgram = null;
        instance = new(shell.Packaged, () => Dispatcher.BeginInvoke(() => OpenMain()));
        if (!instance.IsOwner) { if (!await instance.ActivateExistingAsync()) MessageBox.Show("Barback is already running in another session or cannot be reached.", "Barback"); Shutdown(); return; }
        // Keep notification failures outside supervision initialization.
        shell.RegisterNotifications(id => Dispatcher.BeginInvoke(() => { notificationProgram = id; if (MainWindow is MainWindow main) { OpenMain(); main.SelectProgram(id); } }));
        try
        {
            Directory.CreateDirectory(shell.Root);
            var sid = WindowsIdentity.GetCurrent().User!;
            var acl = new System.Security.AccessControl.DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(sid, System.Security.AccessControl.FileSystemRights.FullControl, System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit, System.Security.AccessControl.PropagationFlags.None, System.Security.AccessControl.AccessControlType.Allow));
            acl.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), System.Security.AccessControl.FileSystemRights.FullControl, System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit, System.Security.AccessControl.PropagationFlags.None, System.Security.AccessControl.AccessControlType.Allow));
            System.IO.FileSystemAclExtensions.SetAccessControl(new DirectoryInfo(shell.Root), acl);
            try { store = await SqliteStore.OpenAsync(shell.Root); }
            catch (Exception databaseError)
            {
                var recovery = new RecoveryWindow(shell.Root, databaseError);
                recovery.ShowDialog();
                if (!recovery.Restored) { shell.Dispose(); instance?.Dispose(); instance = null; Shutdown(1); return; }
                store = await SqliteStore.OpenAsync(shell.Root);
            }
            var language = await store.GetSettingAsync("language"); if (language is not null) CultureInfo.CurrentUICulture = new CultureInfo(language);
            WorkbenchTheme.Initialize();
            WorkbenchTheme.Set(await store.GetSettingAsync("theme") ?? "System");
            CloseExits = await store.GetSettingAsync("close_exits") == "true";
            shell.NotificationsEnabled = await store.GetSettingAsync("notifications") != "false";
            var logRoot = Path.Combine(shell.Root, "logs"); Directory.CreateDirectory(logRoot);
            var quota = new LogQuota(1024L * 1024 * 1024, Directory.EnumerateFiles(logRoot, "*", SearchOption.AllDirectories).Where(path => !path.EndsWith(".gaps", StringComparison.Ordinal)).Sum(path => new FileInfo(path).Length));
            store.LogQuota = quota;
            var host = new WindowsProcessHost(Path.Combine(AppContext.BaseDirectory, "Barback.ConsoleHost.exe"), quota);
            host.SetApplicationEnvironment(await ApplicationEnvironment.LoadAsync(store, new DpapiProtector()));
            supervisor = new(store, host, new WindowsClock(), Path.Combine(shell.Root, "logs"));
            supervisor.Attention += shell.Notify;
            var main = new MainWindow(supervisor, store, shell, host); MainWindow = main;
            tray = new TrayAdapter(main, supervisor, () => ExitAsync());
            await supervisor.InitializeAsync();
            SessionEnding += (_, _) => StopForSessionEnd();
            var startup = e.Args.Any(a => a.Equals("--startup", StringComparison.OrdinalIgnoreCase));
            try { startup |= Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs().Kind == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.StartupTask; }
            catch { /* Failure to query optional Shell activation does not affect supervision. */ }
            if (!startup || notificationProgram is not null || pendingActivation) { OpenMain(); main.SelectProgram(notificationProgram); }
        }
        catch (Exception ex)
        {
            MessageBox.Show("Barback could not open its data. Existing files were preserved.\n" + ex.Message + "\n" + shell.Root, "Barback", MessageBoxButton.OK, MessageBoxImage.Error);
            if (supervisor is not null) await supervisor.DisposeAsync(); if (store is not null) await store.DisposeAsync(); tray?.Dispose(); shell.Dispose(); instance?.Dispose(); instance = null; Shutdown(1);
        }
    }
    /// <summary>Synchronous and bounded: WPF shuts the dispatcher down as soon as this handler returns.</summary>
    private void StopForSessionEnd()
    {
        var current = supervisor;
        if (exiting || current is null) return;
        exiting = true;
        try
        {
            // Task.Run drops the UI synchronization context; the whole stop stays inside the 5 s local budget.
            Task.Run(() => current.ShutdownAsync(TimeSpan.FromSeconds(2), forceBudget: TimeSpan.FromSeconds(2.5))).Wait(TimeSpan.FromSeconds(5));
        }
        catch (AggregateException) { /* Unconfirmed cleanup leaves run records interrupted; the next start recovers. */ }
    }
    public void OpenMain() { if (MainWindow is null) { pendingActivation = true; return; } pendingActivation = false; MainWindow.Show(); if (MainWindow.WindowState == WindowState.Minimized) MainWindow.WindowState = WindowState.Normal; MainWindow.Activate(); }
    public async Task ExitAsync()
    {
        if (exiting || supervisor is null) return;
        if (MainWindow is MainWindow workbench && !await workbench.RequestLeaveEditorAsync()) return;
        foreach (var editor in Windows.OfType<Window>().Where(w => w is EditorWindow or EnvironmentWindow).ToArray()) { editor.Close(); if (Windows.OfType<Window>().Contains(editor)) return; }
        if (supervisor.Snapshot.Any(s => s.Runtime.Active) && MessageBox.Show(Text.Get("ExitConfirm"), "Barback", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
        exiting = true;
        using var cancellation = new CancellationTokenSource();
        var force = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var budget = TimeSpan.FromSeconds(25);
        ExitProgressWindow? progress = null;
        if (supervisor.Snapshot.Any(s => s.Runtime.Active)) { progress = new(supervisor, budget, cancellation, force); if (MainWindow?.IsVisible == true) progress.Owner = MainWindow; progress.Show(); }
        try { await supervisor.ShutdownAsync(budget, cancellation.Token, force.Task); progress?.Finish(); await supervisor.DisposeAsync(); tray?.Dispose(); shell?.Dispose(); if (store is not null) await store.DisposeAsync(); instance?.Dispose(); instance = null; Shutdown(); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { exiting = false; }
        catch (Exception ex) { exiting = false; MessageBox.Show(ex.Message, "Barback", MessageBoxButton.OK, MessageBoxImage.Error); }
        finally { progress?.Finish(); }
    }
    protected override void OnExit(ExitEventArgs e) { WorkbenchTheme.Dispose(); instance?.Dispose(); tray?.Dispose(); shell?.Dispose(); base.OnExit(e); }
}
