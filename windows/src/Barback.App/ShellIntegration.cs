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
    private readonly Dictionary<string, DateTimeOffset> sent = [];
    public bool Packaged { get; }
    public string Root { get; }
    public string? NotificationError { get; private set; }
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
        catch (Exception ex) { NotificationError = ex.Message; }
    }
    public void Notify(EventRecord e)
    {
        if (!registered || !NotificationsEnabled) return;
        var key = $"{e.ProgramId}:{e.Type}"; if (sent.TryGetValue(key, out var at) && DateTimeOffset.UtcNow - at < TimeSpan.FromMinutes(10)) return;
        sent[key] = DateTimeOffset.UtcNow;
        try
        {
            var builder = new AppNotificationBuilder().AddText("Barback").AddText(Text.Get("Error"));
            if (e.ProgramId is Guid id) builder.AddArgument("program", id.ToString());
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception ex) { NotificationError = ex.Message; }
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
            ZipFile.CreateFromDirectory(temp, destination);
        }
        finally { Directory.Delete(temp, true); }
    }
    public void Dispose() { if (registered) { registered = false; try { AppNotificationManager.Default.Unregister(); } catch { } } }
}
