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
    // Until the data directory exists, diagnostics go to %TEMP%\Barback\startup.log; afterwards to <data>\logs\app\barback.log.
    private AppLog log = new(Path.Combine(Path.GetTempPath(), "Barback"), fileName: "startup.log");
    private string? lastStorageError;
    private bool pendingActivation;
    public bool IsExiting => exiting;
    public bool CloseExits { get; set; }
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => log.Error("appdomain", args.IsTerminating ? "Unhandled exception (terminating)." : "Unhandled exception.", args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) => { log.Warning("task", "Unobserved task exception.", args.Exception); args.SetObserved(); };
        // Match the Windows API baseline and MSIX MinVersion (Windows 10 2004).
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) { MessageBox.Show("Barback requires Windows 10 version 2004 (build 19041) or later.", "Barback"); Shutdown(1); return; }
        DispatcherUnhandledException += (_, args) => { log.Error("dispatcher", "Unhandled UI exception.", args.Exception); MessageBox.Show(args.Exception.Message, "Barback", MessageBoxButton.OK, MessageBoxImage.Error); args.Handled = true; };
        using var identity = WindowsIdentity.GetCurrent();
        if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) { MessageBox.Show("Barback must run as a standard user. Close it and launch without administrator privileges.", "Barback"); Shutdown(1); return; }
        shell = new(); shell.Log = log;
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
            log = new(Path.Combine(shell.Root, "logs", "app")); shell.Log = log;
            try { store = await SqliteStore.OpenAsync(shell.Root); }
            catch (Exception databaseError)
            {
                log.Error("storage", "The database could not be opened; offering recovery.", databaseError);
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
            // Only user-visible program output counts against the budget; the app's own log has its own bounds.
            var quota = new LogQuota(1024L * 1024 * 1024, await Task.Run(() => MeasureOutput(logRoot)));
            store.LogQuota = quota;
            var host = new WindowsProcessHost(Path.Combine(AppContext.BaseDirectory, "Barback.ConsoleHost.exe"), quota);
            host.SetApplicationEnvironment(await ApplicationEnvironment.LoadAsync(store, new DpapiProtector()));
            supervisor = new(store, host, new WindowsClock(), Path.Combine(shell.Root, "logs"));
            var current = supervisor;
            supervisor.Attention += e => shell.Notify(e, e.ProgramId is Guid program ? current.Snapshot.FirstOrDefault(s => s.Config.Id == program)?.Config.Name : null);
            supervisor.Diagnostic = (message, error) => log.Error("supervisor", message, error);
            supervisor.Changed += () =>
            {
                var storageError = current.StorageError;
                if (storageError == lastStorageError) return;
                lastStorageError = storageError;
                if (storageError is null) log.Info("storage", "Storage recovered."); else log.Error("storage", "Storage failure: " + storageError);
            };
            quota.Pressure += supervisor.RequestMaintenance;
            var main = new MainWindow(supervisor, store, shell, host); MainWindow = main;
            tray = new TrayAdapter(main, supervisor, () => ExitAsync());
            await supervisor.InitializeAsync();
            log.Info("app", $"Started: version {typeof(App).Assembly.GetName().Version}, {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}, packaged={shell.Packaged}, programs={supervisor.Snapshot.Count}");
            SessionEnding += (_, _) => StopForSessionEnd();
            var startup = e.Args.Any(a => a.Equals("--startup", StringComparison.OrdinalIgnoreCase));
            try { startup |= Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs().Kind == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.StartupTask; }
            catch { /* Failure to query optional Shell activation does not affect supervision. */ }
            if (!startup || notificationProgram is not null || pendingActivation) { OpenMain(); main.SelectProgram(notificationProgram); }
        }
        catch (Exception ex)
        {
            log.Error("app", "Barback could not open its data.", ex);
            MessageBox.Show("Barback could not open its data. Existing files were preserved.\n" + ex.Message + "\n" + shell.Root, "Barback", MessageBoxButton.OK, MessageBoxImage.Error);
            if (supervisor is not null) await supervisor.DisposeAsync(); if (store is not null) await store.DisposeAsync(); tray?.Dispose(); shell.Dispose(); instance?.Dispose(); instance = null; Shutdown(1);
        }
    }
    /// <summary>Synchronous and bounded: WPF shuts the dispatcher down as soon as this handler returns.</summary>
    private void StopForSessionEnd()
    {
        var current = supervisor;
        if (exiting || current is null) return;
        exiting = true; log.Info("app", "Session ending; stopping programs.");
        try
        {
            // Task.Run drops the UI synchronization context; the whole stop stays inside the 5 s local budget.
            Task.Run(() => current.ShutdownAsync(TimeSpan.FromSeconds(2), forceBudget: TimeSpan.FromSeconds(2.5))).Wait(TimeSpan.FromSeconds(5));
        }
        catch (AggregateException ex) { log.Error("app", "Stopping programs at session end failed; the next start recovers.", ex.GetBaseException()); } // run records stay interrupted
    }
    private static long MeasureOutput(string logRoot)
    {
        long total = 0;
        foreach (var area in new[] { "programs", "runs" })
        {
            var directory = Path.Combine(logRoot, area); if (!Directory.Exists(directory)) continue;
            try
            {
                foreach (var path in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
                {
                    if (path.EndsWith(".gaps", StringComparison.Ordinal)) continue;
                    try { total += new FileInfo(path).Length; } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { } // vanished or locked: not counted
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { } // a directory removed mid-scan must not stop startup
        }
        return total;
    }
    public void OpenMain() { if (MainWindow is null) { pendingActivation = true; return; } pendingActivation = false; MainWindow.Show(); if (MainWindow.WindowState == WindowState.Minimized) MainWindow.WindowState = WindowState.Normal; MainWindow.Activate(); }
    public async Task ExitAsync()
    {
        if (exiting || supervisor is null) return;
        if (MainWindow is MainWindow workbench && !await workbench.RequestLeaveEditorAsync()) return;
        foreach (var editor in Windows.OfType<Window>().Where(w => w is EditorWindow or EnvironmentWindow).ToArray()) { editor.Close(); if (Windows.OfType<Window>().Contains(editor)) return; }
        if (supervisor.Snapshot.Any(s => s.Runtime.Active) && MessageBox.Show(Text.Get("ExitConfirm"), "Barback", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
        exiting = true; log.Info("app", "Exiting.");
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
