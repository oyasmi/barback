using System.Diagnostics;
using System.IO.Compression;
using System.Text.Json;
using Barback.Core;
using Barback.Storage;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.ApplicationModel;
using Windows.Storage;
namespace Barback.App;

public sealed class ShellIntegration : IDisposable
{
    private bool registered;
    public bool Packaged { get; }
    public string Root { get; }
    public string? NotificationError { get; private set; }
    public AppLog? Log { get; set; }
    private readonly NotificationThrottle throttle = new();
    public bool NotificationsEnabled { get; set; } = true;
    public ShellIntegration()
    {
        try { _ = Package.Current.Id; Packaged = true; Root = Path.Combine(ApplicationData.Current.LocalFolder.Path, "Barback"); }
        catch { Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Barback", "Dev"); }
    }
    public void RegisterNotifications(Action<Guid?> navigate)
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, args) =>
            {
                // Notification arguments are navigation identifiers, never actions or commands.
                var query = args.Argument.Split('&').Select(x => x.Split('=', 2)).FirstOrDefault(x => x.Length == 2 && x[0] == "program");
                navigate(query is not null && Guid.TryParse(query[1], out var id) ? id : null);
            };
            AppNotificationManager.Default.Register(); registered = true;
        }
        catch (Exception ex) { NotificationError = ex.Message; Log?.Error("notification", "Notification registration failed.", ex); }
    }
    private static string Body(EventRecord e) => e.Type switch
    {
        "Fatal" => Text.Format("NotifyFatal", Summary(e.Detail)),
        "RunFailed" => e.ExitCode is uint code ? Text.Format("NotifyRunFailed", code, $"0x{code:X8}") : Text.Get("NotifyRunFailedUnknown"),
        "RunTimeout" => Text.Get("NotifyRunTimeout"),
        "CleanupFailed" => Text.Get("NotifyCleanupFailed"),
        "LogIncomplete" => Text.Get("NotifyLogIncomplete"),
        "AppInterrupted" => Text.Get("NotifyAppInterrupted"),
        _ => Text.Get("Error")
    };
    private static string Summary(string detail) { var line = detail.Split('\n')[0].Trim(); return line.Length <= 160 ? line : line[..160] + "…"; }
    public void Notify(EventRecord e, string? programName)
    {
        if (!registered || !NotificationsEnabled || !throttle.ShouldNotify(e)) return;
        try
        {
            var builder = new AppNotificationBuilder().AddText(programName ?? "Barback").AddText(Body(e));
            if (e.ProgramId is Guid id) builder.AddArgument("program", id.ToString());
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception ex) { NotificationError = ex.Message; Log?.Error("notification", "Could not show a notification.", ex); }
    }
    public async Task<string> StartupStateAsync() => !Packaged ? "MSIX required" : (await StartupTask.GetAsync("BarbackStartup")).State.ToString();
    public async Task SetStartupAsync(bool enable)
    {
        if (!Packaged) throw new InvalidOperationException("Login startup requires a signed MSIX installation.");
        var task = await StartupTask.GetAsync("BarbackStartup");
        if (!enable) { task.Disable(); return; }
        if (task.State is StartupTaskState.DisabledByUser or StartupTaskState.DisabledByPolicy) { Open("ms-settings:startupapps"); return; }
        await task.RequestEnableAsync();
    }
    public static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    public async Task DiagnosticsAsync(string destination, Supervisor supervisor, SqliteStore store)
    {
        var temp = Path.Combine(Path.GetTempPath(), "barback-diagnostics-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(temp);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(temp, "system.json"), JsonSerializer.Serialize(new { app = typeof(App).Assembly.GetName().Version?.ToString(), architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), os = Environment.OSVersion.ToString(), schema = SqliteStore.SchemaVersion, packaged = Packaged }));
            var configs = supervisor.Snapshot.Select(x => new { x.Config.Id, x.Config.Name, x.Config.Kind, x.Config.Enabled, x.Config.Version, x.Runtime.Phase, x.Runtime.Generation, x.Runtime.ExitCode, mode = x.Config.Launch.Mode, stop = x.Config.Launch.StopMode, environmentKeys = x.Config.Launch.Environment.Select(e => new { e.Key, e.Sensitive, e.Remove }) });
            await File.WriteAllTextAsync(Path.Combine(temp, "config-structure.json"), JsonSerializer.Serialize(configs));
            // Event details may contain OS-generated command paths; export stable fields only.
            await File.WriteAllTextAsync(Path.Combine(temp, "events.json"), JsonSerializer.Serialize((await store.EventsAsync()).Select(e => new { e.At, e.Type, e.ProgramId, e.RunId })));
            // Barback's own log (never program output); opened with shared access because it is still being written.
            var appLogs = Path.Combine(Root, "logs", "app");
            if (Directory.Exists(appLogs))
            {
                var target = Path.Combine(temp, "app-log"); Directory.CreateDirectory(target);
                foreach (var file in Directory.GetFiles(appLogs, "barback.log*"))
                {
                    try
                    {
                        await using var source = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                        await using var copy = new FileStream(Path.Combine(target, Path.GetFileName(file)), FileMode.Create, FileAccess.Write);
                        await source.CopyToAsync(copy);
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                }
            }
            // A confirmed overwrite must replace the existing file, so build the archive beside it and move it into place.
            var staging = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try { ZipFile.CreateFromDirectory(temp, staging); File.Move(staging, destination, overwrite: true); }
            finally { if (File.Exists(staging)) File.Delete(staging); }
        }
        finally { Directory.Delete(temp, true); }
    }
    public void Dispose() { if (registered) { registered = false; try { AppNotificationManager.Default.Unregister(); } catch { } } }
}
