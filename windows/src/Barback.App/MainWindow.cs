using System.Text.Json;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Input;
using System.Windows.Threading;
using Barback.Core;
using Barback.Storage;
using Barback.Windows;
using Microsoft.Win32;
namespace Barback.App;

public sealed record ProgramRow(Guid Id, string Name, string Group, string Kind, string Status, int? Pid, long? RunVersion, string Detail, ProgramSnapshot Snapshot);
public sealed class MainWindow : Window
{
    private readonly Supervisor supervisor;
    private readonly SqliteStore store;
    private readonly ShellIntegration shell;
    private readonly WindowsProcessHost host;
    private readonly TabControl tabs = new();
    private readonly DataGrid programs = Grid(), history = Grid(), events = Grid();
    private readonly TextBox search = new() { MinWidth = 180, MaxWidth = 400 };
    private readonly ComboBox kindFilter = new(), groupFilter = new();
    private readonly TextBlock banner = new() { TextWrapping = TextWrapping.Wrap, Margin = new(12) };
    private readonly TextBlock metrics = new() { Margin = new(12) };
    private readonly TextBox historySearch = new() { Width = 200, Margin = new(8) }, eventSearch = new() { Width = 220, Margin = new(8) };
    private readonly DatePicker historySince = new() { Margin = new(8), SelectedDate = DateTime.Today.AddDays(-30) };
    private readonly ComboBox outcomeFilter = new() { Margin = new(8) };
    private RunRecord[] loadedRuns = [];
    private EventRecord[] loadedEvents = [];
    private readonly TextBlock startupState = new() { Margin = new(12) };
    private readonly DispatcherTimer sampler = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly Dictionary<Guid, (TimeSpan Cpu, DateTime At)> lastMetrics = [];
    private readonly Dictionary<string, LogWindow> logWindows = [];
    private bool hiddenHint;
    public MainWindow(Supervisor supervisor, SqliteStore store, ShellIntegration shell, WindowsProcessHost host)
    {
        this.supervisor = supervisor; this.store = store; this.shell = shell; this.host = host;
        Title = "Barback"; Width = 1120; Height = 760; MinWidth = Math.Min(800, SystemParameters.WorkArea.Width); MinHeight = Math.Min(560, SystemParameters.WorkArea.Height);
        Width = Math.Min(Width, SystemParameters.WorkArea.Width); Height = Math.Min(Height, SystemParameters.WorkArea.Height);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var root = new DockPanel(); Content = root;
        DockPanel.SetDock(banner, Dock.Top); root.Children.Add(banner);
        var footer = new StackPanel { Orientation = Orientation.Horizontal }; DockPanel.SetDock(footer, Dock.Bottom); footer.Children.Add(Button("Exit", () => ((App)Application.Current).ExitAsync())); footer.Children.Add(metrics); root.Children.Add(footer); root.Children.Add(tabs);
        BuildPrograms();
        var historyPage = new DockPanel(); var rerun = Button("Start", async () => { if (history.SelectedItem is HistoryRow row && Confirm("RerunConfirm")) { var config = supervisor.Snapshot.FirstOrDefault(x => x.Config.Id == row.ProgramId)?.Config; if (config is not null && config.Kind == ProgramKind.Oneshot) await supervisor.SendAsync(config.Id, Signal.Start); } }); DockPanel.SetDock(rerun, Dock.Top); historyPage.Children.Add(rerun);
        var historyFilters = new WrapPanel(); DockPanel.SetDock(historyFilters, Dock.Top); historyFilters.Children.Add(historySearch); historyFilters.Children.Add(historySince);
        outcomeFilter.ItemsSource = new[] { Text.Get("All") }.Concat(Enum.GetValues<Phase>().Select(Text.Status)).ToArray(); outcomeFilter.SelectedIndex = 0; historyFilters.Children.Add(outcomeFilter); historyPage.Children.Add(historyFilters); historyPage.Children.Add(history);
        historySearch.TextChanged += (_, _) => FilterHistory(); historySince.SelectedDateChanged += (_, _) => FilterHistory(); outcomeFilter.SelectionChanged += (_, _) => FilterHistory();
        tabs.Items.Add(new TabItem { Header = Text.Get("History"), Content = historyPage }); var eventPage = new DockPanel(); DockPanel.SetDock(eventSearch, Dock.Top); eventPage.Children.Add(eventSearch); eventPage.Children.Add(events);
        eventSearch.TextChanged += (_, _) => FilterEvents(); tabs.Items.Add(new TabItem { Header = Text.Get("Events"), Content = eventPage });
        tabs.Items.Add(new TabItem { Header = Text.Get("Settings"), Content = BuildSettings() });
        history.AutoGenerateColumns = false;
        Column(history, "Time", nameof(RunRecord.Started)); Column(history, "Name", nameof(HistoryRow.ProgramName)); Column(history, "Outcome", "DisplayOutcome"); Column(history, "Code", "DisplayCode"); Column(history, "Reason", nameof(RunRecord.Reason));
        var historyMenu = new ContextMenu(); var openOutput = new MenuItem { Header = Text.Get("Logs") }; openOutput.Click += async (_, _) => await RunGuardedAsync(OpenHistoryOutputAsync); historyMenu.Items.Add(openOutput); history.ContextMenu = historyMenu;
        history.MouseDoubleClick += async (_, _) => await RunGuardedAsync(OpenHistoryOutputAsync);
        tabs.SelectionChanged += async (_, e) => { if (e.Source == tabs) await RunGuardedAsync(RefreshPageAsync); };
        search.TextChanged += (_, _) => RefreshPrograms(); kindFilter.SelectionChanged += (_, _) => RefreshPrograms(); groupFilter.SelectionChanged += (_, _) => RefreshPrograms();
        supervisor.Changed += () => Dispatcher.BeginInvoke(RefreshPrograms);
        sampler.Tick += (_, _) => Sample(); IsVisibleChanged += (_, _) => { if (IsVisible) sampler.Start(); else { sampler.Stop(); lastMetrics.Clear(); } };
        PreviewKeyDown += OnKey;
        Closing += OnClosing;
        Loaded += async (_, _) => await RunGuardedAsync(() => WindowPlacement.RestoreAsync(this, store));
        RefreshPrograms();
    }
    private static DataGrid Grid() => new() { IsReadOnly = true, AutoGenerateColumns = true, SelectionMode = DataGridSelectionMode.Single, EnableRowVirtualization = true, EnableColumnVirtualization = true, Margin = new(12), CanUserAddRows = false };
    private static void Column(DataGrid grid, string label, string property) => grid.Columns.Add(new DataGridTextColumn { Header = Text.Get(label), Binding = new System.Windows.Data.Binding(property), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
    public static Button Button(string label, Func<Task> action) { var b = new Button { Content = Text.Get(label) }; b.Click += async (_, _) => { b.IsEnabled = false; try { await RunGuardedAsync(action); } finally { b.IsEnabled = true; } }; return b; }
    public static async Task RunGuardedAsync(Func<Task> action) { try { await action(); } catch (Exception ex) { MessageBox.Show(Text.Get("Error") + "\n" + ex.Message, "Barback", MessageBoxButton.OK, MessageBoxImage.Error); } }
    public static bool Confirm(string key) => MessageBox.Show(Text.Get(key), "Barback", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) == MessageBoxResult.OK;
    private void BuildPrograms()
    {
        var page = new DockPanel(); var top = new WrapPanel { Margin = new(12) }; DockPanel.SetDock(top, Dock.Top); page.Children.Add(top);
        top.Children.Add(Button("AddService", () => EditAsync(null, ProgramKind.Service))); top.Children.Add(Button("AddOneshot", () => EditAsync(null, ProgramKind.Oneshot))); top.Children.Add(Button("Import", () => { new ImportWindow(supervisor) { Owner = this }.ShowDialog(); return Task.CompletedTask; }));
        search.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("Search")); search.ToolTip = Text.Get("Search"); top.Children.Add(search);
        kindFilter.ItemsSource = new[] { "All", Text.Get("AddService"), Text.Get("AddOneshot") }; kindFilter.SelectedIndex = 0; kindFilter.Margin = new(8); top.Children.Add(kindFilter);
        groupFilter.ItemsSource = new[] { "All" }; groupFilter.SelectedIndex = 0; groupFilter.MinWidth = 100; top.Children.Add(groupFilter);
        var bottom = new WrapPanel { Margin = new(12) }; DockPanel.SetDock(bottom, Dock.Bottom); page.Children.Add(bottom);
        bottom.Children.Add(Button("Start", () => SelectedAsync(Signal.Start))); bottom.Children.Add(Button("Stop", () => SelectedAsync(Signal.Stop))); bottom.Children.Add(Button("Restart", () => SelectedAsync(Signal.Restart))); bottom.Children.Add(Button("Force", async () => { if (Confirm("ForceConfirm")) await SelectedAsync(Signal.Force); }));
        bottom.Children.Add(Button("ClearFailure", () => SelectedAsync(Signal.ClearFailure)));
        bottom.Children.Add(Button("Edit", () => EditSelectedAsync())); bottom.Children.Add(Button("Copy", CopyAsync)); bottom.Children.Add(Button("Delete", DeleteAsync)); bottom.Children.Add(Button("Logs", OpenSelectedLogsAsync));
        bottom.Children.Add(Button("StartAll", () => supervisor.BatchAsync(Signal.Start))); bottom.Children.Add(Button("StopAll", async () => { if (Confirm("StopConfirm")) await supervisor.BatchAsync(Signal.Stop); })); bottom.Children.Add(Button("RestartAll", async () => { if (Confirm("RestartConfirm")) await supervisor.BatchAsync(Signal.Restart); }));
        programs.AutoGenerateColumns = false; Column(programs, "Name", nameof(ProgramRow.Name)); Column(programs, "Group", nameof(ProgramRow.Group)); Column(programs, "Status", nameof(ProgramRow.Status)); Column(programs, "Pid", nameof(ProgramRow.Pid)); Column(programs, "ConfigVersion", nameof(ProgramRow.RunVersion)); Column(programs, "Detail", nameof(ProgramRow.Detail));
        programs.MouseDoubleClick += async (_, _) => await RunGuardedAsync(EditSelectedAsync);
        programs.ContextMenu = new ContextMenu(); foreach (var (label, signal) in new[] { ("Start", Signal.Start), ("Stop", Signal.Stop), ("Restart", Signal.Restart) }) { var menu = new MenuItem { Header = Text.Get(label) }; menu.Click += async (_, _) => await RunGuardedAsync(() => SelectedAsync(signal)); programs.ContextMenu.Items.Add(menu); }
        page.Children.Add(programs); tabs.Items.Add(new TabItem { Header = Text.Get("Programs"), Content = page });
    }
    private UIElement BuildSettings()
    {
        var panel = new StackPanel { Margin = new(24), MaxWidth = 880, HorizontalAlignment = HorizontalAlignment.Left };
        var close = new CheckBox { Content = Text.Get("CloseExit"), IsChecked = ((App)Application.Current).CloseExits, Margin = new(8) };
        close.Click += async (_, _) => await RunGuardedAsync(async () => { await store.SetSettingAsync("close_exits", close.IsChecked == true ? "true" : "false"); ((App)Application.Current).CloseExits = close.IsChecked == true; }); panel.Children.Add(close);
        var notifications = new CheckBox { Content = Text.Get("Notifications"), IsChecked = shell.NotificationsEnabled, Margin = new(8) };
        notifications.Click += async (_, _) => await RunGuardedAsync(async () => { await store.SetSettingAsync("notifications", notifications.IsChecked == true ? "true" : "false"); shell.NotificationsEnabled = notifications.IsChecked == true; }); panel.Children.Add(notifications);
        panel.Children.Add(startupState); panel.Children.Add(Button("LoginEnable", async () => { await shell.SetStartupAsync(true); startupState.Text = await shell.StartupStateAsync(); })); panel.Children.Add(Button("LoginDisable", async () => { await shell.SetStartupAsync(false); startupState.Text = await shell.StartupStateAsync(); })); panel.Children.Add(Button("LoginSettings", () => { ShellIntegration.Open("ms-settings:startupapps"); return Task.CompletedTask; }));
        panel.Children.Add(new TextBlock { Text = Text.Get("Language"), Margin = new(8) }); var language = new ComboBox { ItemsSource = new[] { "zh-Hans", "en-US" }, SelectedItem = System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh") ? "zh-Hans" : "en-US", Margin = new(8) };
        language.SelectionChanged += async (_, _) => await RunGuardedAsync(() => store.SetSettingAsync("language", (string)language.SelectedItem)); panel.Children.Add(language);
        panel.Children.Add(Button("Environment", () => { new EnvironmentWindow(store, host) { Owner = this }.ShowDialog(); return Task.CompletedTask; }));
        panel.Children.Add(Button("RefreshEnvironment", () => { host.RefreshEnvironment(); banner.Text = Text.Get("Pending"); return Task.CompletedTask; }));
        panel.Children.Add(new TextBlock { Text = shell.Root, TextWrapping = TextWrapping.Wrap, Margin = new(8) }); panel.Children.Add(Button("OpenData", () => { ShellIntegration.Open(shell.Root); return Task.CompletedTask; }));
        panel.Children.Add(Button("Backup", async () => { var dialog = new SaveFileDialog { Filter = "SQLite|*.db", FileName = "barback-backup.db" }; if (dialog.ShowDialog(this) == true) await store.BackupDatabaseAsync(dialog.FileName); }));
        panel.Children.Add(Button("Export", async () => { var dialog = new SaveFileDialog { Filter = "JSON|*.json", FileName = "barback-config.json" }; if (dialog.ShowDialog(this) == true) await store.ExportPortableAsync(dialog.FileName); }));
        panel.Children.Add(Button("Restore", RestoreAsync));
        panel.Children.Add(Button("Diagnostics", async () => { var dialog = new SaveFileDialog { Filter = "ZIP|*.zip", FileName = "barback-diagnostics.zip" }; if (dialog.ShowDialog(this) == true) await shell.DiagnosticsAsync(dialog.FileName, supervisor, store); }));
        panel.Children.Add(Button("Updates", () => { ShellIntegration.Open("https://github.com/oyasmi/barback/releases"); return Task.CompletedTask; }));
        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
    public void SelectProgram(Guid? id) { tabs.SelectedIndex = 0; if (id is Guid value) programs.SelectedItem = ((IEnumerable<ProgramRow>)programs.ItemsSource).FirstOrDefault(x => x.Id == value); }
    public void ShowPage(int index) { ((App)Application.Current).OpenMain(); tabs.SelectedIndex = Math.Clamp(index, 0, tabs.Items.Count - 1); }
    private void RefreshPrograms()
    {
        var selected = (programs.SelectedItem as ProgramRow)?.Id;
        var oldGroup = groupFilter.SelectedItem as string;
        var groups = new[] { "All" }.Concat(supervisor.Snapshot.Select(x => x.Config.Group).Where(x => x.Length > 0).Distinct().Order()).ToArray();
        if (groupFilter.ItemsSource is not string[] current || !current.SequenceEqual(groups)) { groupFilter.ItemsSource = groups; groupFilter.SelectedItem = groups.Contains(oldGroup) ? oldGroup : "All"; }
        var query = search.Text.Trim();
        var rows = supervisor.Snapshot.Where(x => (query.Length == 0 || x.Config.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || x.Config.Group.Contains(query, StringComparison.OrdinalIgnoreCase)) && (kindFilter.SelectedIndex < 1 || x.Config.Kind == (kindFilter.SelectedIndex == 1 ? ProgramKind.Service : ProgramKind.Oneshot)) && (groupFilter.SelectedItem is not string g || g == "All" || x.Config.Group == g))
            .Select(x => new ProgramRow(x.Config.Id, x.Config.Name, x.Config.Group, x.Config.Kind.ToString(), x.Runtime.Cleaning ? Text.Get("CleaningChildren") : Text.Status(x.Runtime.Phase), x.Runtime.Pid, x.Runtime.Active ? x.Runtime.ConfigVersion : null, x.Runtime.Error ?? (x.Runtime.Active && x.Config.Version != x.Runtime.ConfigVersion ? Text.Get("Pending") : x.Config.Launch.StopMode == StopMode.TerminateJob ? Text.Option(StopMode.TerminateJob) : ""), x)).ToArray();
        var scrolling = Descendants(programs).OfType<ScrollViewer>().FirstOrDefault(); var offset = scrolling?.VerticalOffset;
        programs.ItemsSource = rows; programs.SelectedItem = rows.FirstOrDefault(x => x.Id == selected);
        if (scrolling is not null && offset is double position) Dispatcher.BeginInvoke(() => scrolling.ScrollToVerticalOffset(position));
        banner.Text = supervisor.StorageError ?? (rows.Length == 0 ? Text.Get("NoPrograms") : "");
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); i++) { var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i); yield return child; foreach (var next in Descendants(child)) yield return next; }
    }
    public Task SelectedAsync(Signal signal)
    {
        if (programs.SelectedItem is not ProgramRow row) return Task.CompletedTask;
        if (signal == Signal.Start && row.Snapshot.Runtime.Phase == Phase.Interrupted && !Confirm("InterruptedConfirm")) return Task.CompletedTask;
        return supervisor.SendAsync(row.Id, signal);
    }
    public Task EditSelectedAsync() => programs.SelectedItem is ProgramRow row ? EditAsync(row.Snapshot.Config, row.Snapshot.Config.Kind) : Task.CompletedTask;
    public Task EditAsync(ProgramConfig? config, ProgramKind kind)
    {
        var editor = new EditorWindow(supervisor, config ?? new() { Kind = kind, Name = kind == ProgramKind.Service ? "New service" : "New command", Launch = new() { WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) }, Policy = new() { Autostart = kind == ProgramKind.Service } }) { Owner = this };
        editor.ShowDialog(); return Task.CompletedTask;
    }
    private async Task CopyAsync()
    {
        if (programs.SelectedItem is not ProgramRow row || !Confirm("CopyConfirm")) return;
        var copy = row.Snapshot.Config with { Id = Guid.NewGuid(), Version = 0, Name = row.Name + " copy", Enabled = false, Policy = row.Snapshot.Config.Policy with { Autostart = false } }; await supervisor.SaveAsync(copy, 0);
    }
    private async Task DeleteAsync() { if (programs.SelectedItem is ProgramRow row && Confirm("DeleteConfirm")) await supervisor.DeleteAsync(row.Id); }
    private async Task OpenSelectedLogsAsync()
    {
        if (programs.SelectedItem is not ProgramRow row) return;
        var run = (await store.RunsAsync()).FirstOrDefault(r => r.ProgramId == row.Id); if (run is not null) OpenLog(run, row.Snapshot.Config.Launch.EncodingCodePage);
    }
    private Task OpenHistoryOutputAsync()
    {
        if (history.SelectedItem is HistoryRow row) OpenLog(row.Run, supervisor.Snapshot.FirstOrDefault(x => x.Config.Id == row.Run.ProgramId)?.Config.Launch.EncodingCodePage ?? 65001); return Task.CompletedTask;
    }
    private void OpenLog(RunRecord run, int encoding)
    {
        if (run.LogDirectory is null) { banner.Text = Text.Get("NotLoaded"); return; }
        var key = run.Id.ToString();
        if (logWindows.TryGetValue(key, out var existing)) { existing.Show(); existing.Activate(); return; }
        var window = new LogWindow(run.LogDirectory, encoding); logWindows[key] = window; window.Closed += (_, _) => logWindows.Remove(key); window.Show();
    }
    private sealed record HistoryRow(RunRecord Run, string ProgramName)
    {
        public DateTimeOffset Started => Run.Started.ToLocalTime(); public Guid ProgramId => Run.ProgramId;
        public string DisplayOutcome => Text.Status(Run.Outcome); public string DisplayCode => Run.ExitCode is uint code ? $"{code} (0x{code:X8})" : "—";
        public EndReason? Reason => Run.Reason;
    }
    private async Task RefreshPageAsync()
    {
        if (tabs.SelectedIndex == 1) { loadedRuns = (await store.RunsAsync()).ToArray(); FilterHistory(); }
        if (tabs.SelectedIndex == 2) { loadedEvents = (await store.EventsAsync()).ToArray(); FilterEvents(); }
        if (tabs.SelectedIndex == 3) startupState.Text = (await shell.StartupStateAsync()) + (shell.NotificationError is null ? "" : "\n" + shell.NotificationError);
    }
    private void FilterHistory()
    {
        var names = supervisor.Snapshot.ToDictionary(x => x.Config.Id, x => x.Config.Name);
        history.ItemsSource = loadedRuns.Where(r => (historySince.SelectedDate is not DateTime since || r.Started.LocalDateTime >= since) && (outcomeFilter.SelectedIndex <= 0 || Text.Status(r.Outcome) == (string)outcomeFilter.SelectedItem) && (historySearch.Text.Length == 0 || names.GetValueOrDefault(r.ProgramId, r.ProgramId.ToString()).Contains(historySearch.Text, StringComparison.OrdinalIgnoreCase)))
            .Select(r => new HistoryRow(r, names.GetValueOrDefault(r.ProgramId, r.ProgramId.ToString()))).ToArray();
    }
    private void FilterEvents() => events.ItemsSource = loadedEvents.Where(e => eventSearch.Text.Length == 0 || e.Type.Contains(eventSearch.Text, StringComparison.OrdinalIgnoreCase) || e.Detail.Contains(eventSearch.Text, StringComparison.OrdinalIgnoreCase) || e.ProgramId?.ToString().Contains(eventSearch.Text, StringComparison.OrdinalIgnoreCase) == true).ToArray();
    private void Sample()
    {
        var running = supervisor.Snapshot.Count(x => x.Runtime.Active);
        var stopping = supervisor.Snapshot.Count(x => x.Runtime.Phase == Phase.Stopping);
        if (supervisor.StorageError is null) banner.Text = $"{running} {Text.Get("PhaseRunning")} · {stopping} {Text.Get("PhaseStopping")}";

        if (!IsVisible || tabs.SelectedIndex != 0) return;
        if (programs.SelectedItem is not ProgramRow row || row.Pid is not int pid) { metrics.Text = ""; return; }
        try
        {
            using var process = Process.GetProcessById(pid); if (row.Snapshot.Runtime.CreationTime is not long identity || process.StartTime.ToFileTimeUtc() != identity) { metrics.Text = Text.Get("Unavailable"); return; }
            var cpu = process.TotalProcessorTime; var now = DateTime.UtcNow;
            var percent = lastMetrics.TryGetValue(row.Id, out var old) ? Math.Clamp((cpu - old.Cpu).TotalSeconds / (now - old.At).TotalSeconds / Environment.ProcessorCount * 100, 0, 100) : 0;
            lastMetrics[row.Id] = (cpu, now); metrics.Text = $"{Text.Get("Metrics")}: {percent:F1}% / {process.WorkingSet64 / 1048576d:F1} MiB";
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { metrics.Text = Text.Get("Unavailable"); }
    }
    private async Task RestoreAsync()
    {
        var dialog = new OpenFileDialog { Filter = "Barback configuration|*.json" }; if (dialog.ShowDialog(this) != true) return;
        using var document = System.Text.Json.JsonDocument.Parse(await File.ReadAllTextAsync(dialog.FileName));
        if (!SqliteStore.AcceptsConfigurationSchema(document.RootElement.GetProperty("schemaVersion").GetInt32()) || document.RootElement.GetProperty("sourcePlatform").GetString() != "windows") throw new InvalidDataException("Unsupported backup format.");
        var encrypted = document.RootElement.TryGetProperty("encryptedSecrets", out var flag) && flag.GetBoolean(); var decrypt = new DpapiProtector();
        var restored = new List<ProgramConfig>();
        foreach (var item in document.RootElement.GetProperty("programs").EnumerateArray())
        {
            var c = item.Deserialize<ProgramConfig>()!; var env = c.Launch.Environment.Select(e => e.Sensitive && !e.Remove ? e with { Value = encrypted ? decrypt.Unprotect(e.Value ?? "") : null, NeedsInput = !encrypted || e.NeedsInput } : e).ToArray();
            // Restored entries never overwrite current configurations or start automatically.
            restored.Add(c with { Id = Guid.NewGuid(), Version = 0, Enabled = false, Name = c.Name + " restored", Policy = c.Policy with { Autostart = false }, Launch = c.Launch with { Environment = env } });
        }
        await supervisor.ImportAsync(restored);
    }
    private async void OnKey(object sender, KeyEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0 && e.Key == Key.F) { (tabs.SelectedIndex == 1 ? historySearch : tabs.SelectedIndex == 2 ? eventSearch : search).Focus(); e.Handled = true; }
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0 && e.Key == Key.N) { e.Handled = true; await EditAsync(null, (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? ProgramKind.Oneshot : ProgramKind.Service); }
        if (e.OriginalSource == programs && e.Key == Key.Enter) { e.Handled = true; await EditSelectedAsync(); }
        if (e.OriginalSource is not TextBox && programs.IsKeyboardFocusWithin && e.Key == Key.D && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; await RunGuardedAsync(CopyAsync); }
        if (e.OriginalSource is not TextBox && programs.IsKeyboardFocusWithin && e.Key == Key.Delete) { e.Handled = true; await RunGuardedAsync(DeleteAsync); }
    }
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (((App)Application.Current).IsExiting) { e.Cancel = false; return; }
        e.Cancel = true;
        if (((App)Application.Current).CloseExits) { await ((App)Application.Current).ExitAsync(); return; }
        if (!hiddenHint && await store.GetSettingAsync("hidden_hint") != "true") { MessageBox.Show(Text.Get("Hidden"), "Barback"); hiddenHint = true; await store.SetSettingAsync("hidden_hint", "true"); }
        await WindowPlacement.SaveAsync(this, store); Hide();
    }
}
