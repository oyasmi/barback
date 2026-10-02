using System.Globalization;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Barback.App;
using Barback.Core;
using Barback.Storage;
using Barback.Windows;
using AppWindow = Barback.App.MainWindow;

// Real WPF resources, controls and dispatcher; fake process host and a fresh isolated database.
// No production App startup, singleton, notification registration or real command execution.
internal static class Program
{
    private static string output = "";
    private static readonly List<string> passed = [];
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Length != 1) throw new ArgumentException("Supply an output directory for isolated data and screenshots.");
        output = Path.GetFullPath(args[0]); Directory.CreateDirectory(output);
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("zh-Hans");
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(new() { Source = new Uri("pack://application:,,,/PresentationFramework.Fluent;component/Themes/Fluent.xaml") });
        application.Resources.MergedDictionaries.Add(new() { Source = new Uri("pack://application:,,,/Barback.App;component/Resources/Workbench.xaml") });
        WorkbenchTheme.Initialize(); WorkbenchTheme.Set("Light");
        application.DispatcherUnhandledException += (_, e) => { File.WriteAllText(Path.Combine(output, "error.txt"), e.Exception.ToString()); e.Handled = true; application.Shutdown(1); };
        application.Startup += async (_, _) =>
        {
            try { await RunAsync(application); File.WriteAllLines(Path.Combine(output, "checks.txt"), passed); application.Shutdown(0); }
            catch (Exception ex) { File.WriteAllText(Path.Combine(output, "error.txt"), ex.ToString()); application.Shutdown(1); }
            finally { WorkbenchTheme.Dispose(); }
        };
        application.Run();
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); passed.Add(message); }
    private static async Task PaintAsync(Window window) { await Task.Delay(350); window.UpdateLayout(); }
    private static T Named<T>(AppWindow window, string name) where T : FrameworkElement => (T)window.FindName(name);
    private static IEnumerable<T> Children<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); if (child is T item) yield return item;
            foreach (var nested in Children<T>(child)) yield return nested;
        }
    }
    private static void Capture(Window window, string name)
    {
        var content = (FrameworkElement)window.Content;
        var image = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        image.Render(content); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
        using var file = File.Create(Path.Combine(output, name + ".png")); encoder.Save(file);
    }
    private static async Task UntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(8);
        while (!condition()) { if (DateTime.UtcNow > deadline) throw new TimeoutException(); await Task.Delay(30); }
    }
    private static async Task RunAsync(Application application)
    {
        var root = Path.Combine(output, "data-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var executable = Path.Combine(root, "fixture.exe"); File.WriteAllText(executable, "UI fixture; never executed");
        await using var store = await SqliteStore.OpenAsync(root);
        await store.SetSettingAsync("theme", "Light"); await store.SetSettingAsync("hidden_hint", "true");
        var fakeHost = new Host(); await using var supervisor = new Supervisor(store, fakeHost, new WindowsClock(), Path.Combine(root, "logs"));
        await supervisor.InitializeAsync();
        ProgramConfig Draft(string name, string group, ProgramKind kind = ProgramKind.Service, bool enabled = true) => new()
        {
            Name = name, Group = group, Kind = kind, Enabled = enabled,
            Launch = new() { Executable = executable, WorkingDirectory = root },
            Policy = new() { Autostart = false, StartSeconds = 0, StartRetries = 0, Restart = RestartPolicy.Never }
        };
        var configs = new[] { Draft("API 开发服务", "开发环境"), Draft("前端预览", "开发环境"), Draft("队列 Worker", "后台服务"), Draft("数据库备份", "维护任务", ProgramKind.Oneshot), Draft("同步资料", "维护任务", ProgramKind.Oneshot), Draft("旧版服务", "后台服务", enabled: false) };
        configs[2] = configs[2] with { Launch = configs[2].Launch with { Arguments = ["--fixture-fail"] } };
        foreach (var config in configs) await supervisor.SaveAsync(config, 0);
        await supervisor.SendAsync(configs[2].Id, Signal.Start);
        await UntilAsync(() => supervisor.Snapshot.First(s => s.Config.Id == configs[2].Id).Runtime.Phase == Phase.Fatal);
        await supervisor.SendAsync(configs[0].Id, Signal.Start);
        await UntilAsync(() => supervisor.Snapshot.First(s => s.Config.Id == configs[0].Id).Runtime.Phase == Phase.Running);
        var success = new RunRecord(Guid.NewGuid(), configs[3].Id, 1, 1, DateTimeOffset.UtcNow.AddMinutes(-3), LogDirectory: Path.Combine(root, "backup"));
        Directory.CreateDirectory(success.LogDirectory!); File.WriteAllText(Path.Combine(success.LogDirectory!, "stdout.log"), "备份完成 · 128 个文件\n");
        await store.BeginRunAsync(success); await store.EndRunAsync(success.Id, Phase.Succeeded, EndReason.Natural, 0);
        using var shell = new ShellIntegration();
        var window = new AppWindow(supervisor, store, shell, new WindowsProcessHost("unused-by-ui-fixture")) { ShowActivated = false, Width = 1120, Height = 760 };
        application.MainWindow = window; window.Show(); window.SelectProgram(configs[0].Id); await PaintAsync(window);
        Check(Named<ListBox>(window, "ProgramList").Items.Count == 6, "Six stable program rows rendered");
        Check(Named<Border>(window, "DetailPane").IsVisible && Named<Grid>(window, "CollectionPane").IsVisible, "Wide layout shows list and details together");
        await UntilAsync(() => Children<TextBox>(Named<ContentControl>(window, "LogHost")).Any(t => t.Text.Contains("LISTENING")));
        Check(true, "Live output is loaded into embedded view"); Capture(window, "workbench-light");
        window.SelectProgram(configs[2].Id); await PaintAsync(window);
        Check(Named<Border>(window, "FailurePanel").IsVisible && Named<TextBlock>(window, "AttentionCount").Text == "1", "Failed service exposes reason and attention count"); Capture(window, "failure");
        window.SelectProgram(configs[0].Id); await PaintAsync(window);
        var row = Named<ListBox>(window, "ProgramList").SelectedItem;
        var configNow = supervisor.Snapshot.First(s => s.Config.Id == configs[0].Id).Config;
        await supervisor.SaveAsync(configNow with { Notes = "Metadata only" }, configNow.Version); await PaintAsync(window);
        Check(ReferenceEquals(row, Named<ListBox>(window, "ProgramList").SelectedItem), "State refresh preserves selected row instance");
        Check(Named<Border>(window, "PendingPanel").Visibility == Visibility.Collapsed, "Metadata edit does not claim restart required");
        configNow = supervisor.Snapshot.First(s => s.Config.Id == configs[0].Id).Config;
        await supervisor.SaveAsync(configNow with { Launch = configNow.Launch with { Arguments = ["--new"] } }, configNow.Version); await PaintAsync(window);
        Check(Named<Border>(window, "PendingPanel").IsVisible, "Changed launch configuration shows pending notice");
        var stream = Children<ComboBox>(Named<ContentControl>(window, "LogHost")).Single(); stream.SelectedIndex = 1; await Task.Delay(700);
        Check(!Children<TextBox>(Named<ContentControl>(window, "LogHost")).Any(t => t.Text.Contains("LISTENING")), "Missing stderr never shows previous stdout");
        stream.SelectedIndex = 0; await Task.Delay(700);
        window.SelectProgram(configs[5].Id); await PaintAsync(window);
        Check(!Children<TextBox>(Named<ContentControl>(window, "LogHost")).Any(t => t.Text.Contains("LISTENING")), "Selecting program with no run clears previous output");
        window.SelectProgram(configs[0].Id); await PaintAsync(window); WorkbenchTheme.Set("Dark"); await PaintAsync(window); Capture(window, "workbench-dark");
        Check(((SolidColorBrush)application.FindResource("SurfaceBrush")).Color.R < 80, "Dark palette is applied to live native resources");
        WorkbenchTheme.Set("Light"); window.Width = 800; window.Height = 560; await PaintAsync(window);
        Check(!Named<Grid>(window, "CollectionPane").IsVisible && Named<Border>(window, "DetailPane").IsVisible, "Narrow layout drills into details"); Capture(window, "narrow-detail");
        Named<Button>(window, "BackToList").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await PaintAsync(window);
        Check(Named<Grid>(window, "CollectionPane").IsVisible && !Named<Border>(window, "DetailPane").IsVisible, "Narrow back navigation restores list"); Capture(window, "narrow-list");
        var search = Named<TextBox>(window, "SearchBox"); search.Text = "不存在"; await PaintAsync(window);
        Check(Named<StackPanel>(window, "EmptyState").IsVisible, "Search with no matches shows recoverable empty state"); search.Clear();
        window.Width = 1120; window.Height = 760; window.ShowPage(1); await PaintAsync(window);
        Check(Named<DataGrid>(window, "HistoryTable").Items.Count == 2, "History contains completed results only"); Capture(window, "activity");
        var history = Named<DataGrid>(window, "HistoryTable");
        history.SelectedItem = history.Items.OfType<HistoryRow>().Single(r => r.ProgramId == configs[3].Id);
        Named<Button>(window, "HistoryOutput").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await PaintAsync(window);
        Check(Named<Button>(window, "RerunButton").IsVisible && Named<Button>(window, "RerunButton").IsEnabled, "Completed one-shot history offers explicit rerun with current configuration");
        Check(!Named<Button>(window, "RestartButton").IsVisible, "Historical output has no live restart control");
        window.ShowPage(1); await PaintAsync(window);
        history.SelectedItem = history.Items.OfType<HistoryRow>().Single(r => r.ProgramId == configs[2].Id);
        Named<Button>(window, "HistoryOutput").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await PaintAsync(window);
        Check(!Named<Button>(window, "RerunButton").IsVisible, "Service history never offers rerun");
        await window.EditAsync(supervisor.Snapshot.First(s => s.Config.Id == configs[1].Id).Config, ProgramKind.Service); await PaintAsync(window);
        var editor = (EditorView)Named<ContentControl>(window, "EditorHost").Content;
        var fields = (Dictionary<string, TextBox>)typeof(EditorView).GetField("fields", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(editor)!;
        fields["Name"].Text = "";
        var save = (Task<bool>)typeof(EditorView).GetMethod("SaveAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(editor, [null])!;
        Check(!await save, "Invalid draft fails inline without closing editor");
        Check(Named<ContentControl>(window, "EditorHost").Content == editor && fields["Name"].Text == "", "Validation preserves editor and draft");
        fields["Name"].Text = "前端预览 · 新配置";
        Check(await (Task<bool>)typeof(EditorView).GetMethod("SaveAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(editor, [null])!, "Valid editor draft saves through supervisor");
        Check(!supervisor.Snapshot.First(s => s.Config.Id == configs[1].Id).Runtime.Active, "Saving config never starts an idle program");
        window.Width = 800; window.Height = 560; await PaintAsync(window);
        var saveButton = (Button)typeof(EditorView).GetField("saveButton", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(editor)!;
        var position = saveButton.TranslatePoint(new Point(), window);
        Check(position.Y + saveButton.ActualHeight <= window.ActualHeight && saveButton.IsVisible, "Editor save footer stays visible at minimum window size"); Capture(window, "editor-narrow");
        Check(await window.RequestLeaveEditorAsync(), "Clean saved editor leaves without discarding anything");
        window.Width = 1120; window.Height = 760; window.ShowPage(3); await PaintAsync(window); Capture(window, "settings");
        using (var tray = new TrayAdapter(window, supervisor, () => Task.CompletedTask))
        {
            typeof(TrayAdapter).GetMethod("ShowPanel", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(tray, null);
            var panel = (Window)typeof(TrayAdapter).GetField("panel", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(tray)!;
            await PaintAsync(panel);
            Check(Children<ListBox>(panel).Single().Items.Count == 6, "Native tray uses same six stable program rows");
            Check(Children<Button>(panel).Count(b => b.Content as string == Text.Get("StopService")) == 1, "Tray exposes contextual stop only on owned run");
            Capture(panel, "tray"); panel.Hide();
        }
        var pendingSecret = Draft("待补充敏感值", "维护任务", ProgramKind.Oneshot, enabled: false);
        pendingSecret = pendingSecret with { Launch = pendingSecret.Launch with { Environment = [new("UI_TEST_SECRET", null, Sensitive: true, NeedsInput: true)] } };
        await supervisor.SaveAsync(pendingSecret, 0);
        await window.EditAsync(supervisor.Snapshot.Single(s => s.Config.Id == pendingSecret.Id).Config, ProgramKind.Oneshot); await PaintAsync(window);
        editor = (EditorView)Named<ContentControl>(window, "EditorHost").Content;
        fields = (Dictionary<string, TextBox>)typeof(EditorView).GetField("fields", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(editor)!;
        fields["Notes"].Text = "Metadata edit must preserve re-entry requirement";
        Check(await (Task<bool>)typeof(EditorView).GetMethod("SaveAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(editor, [null])!
            && supervisor.Snapshot.Single(s => s.Config.Id == pendingSecret.Id).Config.Launch.Environment.Single().NeedsInput, "Editing metadata preserves unresolved sensitive value requirement");
        var enabled = (CheckBox)typeof(EditorView).GetField("enabled", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(editor)!;
        enabled.IsChecked = true;
        Check(!await (Task<bool>)typeof(EditorView).GetMethod("SaveAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(editor, [null])!, "Unresolved sensitive value prevents enabling configuration");
        // Expand the environment group so its native password field is in the visual tree.
        foreach (var expander in Children<Expander>(editor)) expander.IsExpanded = true;
        await PaintAsync(window); Children<PasswordBox>(editor).Single().Password = "dummy-ui-fixture-secret";
        Check(await (Task<bool>)typeof(EditorView).GetMethod("SaveAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(editor, [null])!
            && !supervisor.Snapshot.Single(s => s.Config.Id == pendingSecret.Id).Config.Launch.Environment.Single().NeedsInput, "Explicit password re-entry resolves sensitive value requirement");
        await window.RequestLeaveEditorAsync();
        await supervisor.SendAsync(configs[0].Id, Signal.Force); await UntilAsync(() => supervisor.Snapshot.All(s => !s.Runtime.Active));
        window.Close();
    }
    private sealed class Host : IProcessHost
    {
        public bool IsSameProcessAlive(int pid, long creationTime) => false;
        public Task<IProcessRun> PrepareAsync(Guid id, LaunchSpec launch, string directory, Action<long> loss, long? runOutputLimit, CancellationToken token)
        {
            if (launch.Arguments.Contains("--fixture-fail")) throw new IOException("无法连接到任务队列；请检查连接配置。");
            Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "stdout.log"), "09:41:02 INFO  Starting API server\n09:41:02 INFO  Database connection established\n09:41:03 INFO  LISTENING on http://localhost:8080\n09:41:06 INFO  GET /api/health  200  4ms\n");
            return Task.FromResult<IProcessRun>(new Run(id));
        }
    }
    private sealed class Run(Guid id) : IProcessRun
    {
        private readonly TaskCompletionSource<uint> exit = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Guid Id => id; public int Pid => 999999; public long CreationTime => 1; public Task<uint> Exit => exit.Task;
        public Task ActivateAsync(CancellationToken token) => Task.CompletedTask;
        public Task RequestBreakAsync(CancellationToken token) => Task.CompletedTask;
        public Task<bool> CleanAsync(CancellationToken token) { exit.TrySetResult(0); return Task.FromResult(true); }
        public ValueTask DisposeAsync() { exit.TrySetResult(0); return ValueTask.CompletedTask; }
    }
}
