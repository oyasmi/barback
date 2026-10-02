using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Barback.Core;
using Barback.Storage;
using Barback.Windows;
using Microsoft.Win32;

namespace Barback.App;

public partial class MainWindow : Window
{
    private readonly Supervisor supervisor;
    private readonly SqliteStore store;
    private readonly ShellIntegration shell;
    private readonly WindowsProcessHost host;
    private readonly WindowsClock clock = new();
    private readonly ObservableCollection<ProgramRow> rows = [];
    private readonly ICollectionView programView;
    private readonly DispatcherTimer sampler = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<Guid, (TimeSpan Cpu, DateTime At)> lastMetrics = [];
    private readonly Dictionary<Guid, LogWindow> logWindows = [];
    private RunRecord[] loadedRuns = [];
    private EventRecord[] loadedEvents = [];
    private ProgramRow? selected;
    private HistoryRow? historical;
    private string? dismissedStorageError;
    private bool storageBannerShown;
    private LogView? logView;
    private Guid? displayedRun;
    private EditorView? editor;
    private string page = "programs", scope = "all", groupSignature = "";
    private bool ready, refreshing, hiddenHint, narrowDetail, recordsDirty = true, loadingRecords, historyFromActivity, closed, closing;
    private int refreshQueued;

    public MainWindow(Supervisor supervisor, SqliteStore store, ShellIntegration shell, WindowsProcessHost host)
    {
        this.supervisor = supervisor; this.store = store; this.shell = shell; this.host = host;
        programView = CollectionViewSource.GetDefaultView(rows);
        programView.Filter = Matches;
        programView.SortDescriptions.Add(new(nameof(ProgramRow.Group), ListSortDirection.Ascending));
        programView.SortDescriptions.Add(new(nameof(ProgramRow.Name), ListSortDirection.Ascending));
        programView.GroupDescriptions.Add(new PropertyGroupDescription(nameof(ProgramRow.Group)));
        InitializeComponent();
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        MinWidth = Math.Min(800, SystemParameters.WorkArea.Width); MinHeight = Math.Min(560, SystemParameters.WorkArea.Height);
        Width = Math.Min(Width, SystemParameters.WorkArea.Width); Height = Math.Min(Height, SystemParameters.WorkArea.Height);
        ProgramList.ItemsSource = programView;
        KindFilter.ItemsSource = new[] { Text.Get("AllTypes"), Text.Get("ServiceKind"), Text.Get("OneshotKind") }; KindFilter.SelectedIndex = 0;
        OutcomeFilter.ItemsSource = new[] { "All", "RunSuccess", "RunFailed", "RunTimeout", "RunCancelled", "RunInterrupted", "RunExited", "RunUnknown" }
            .Select(key => new FilterChoice(key, Text.Get(key))).ToArray();
        OutcomeFilter.DisplayMemberPath = nameof(FilterChoice.Label); OutcomeFilter.SelectedIndex = 0;
        HistorySince.SelectedDate = DateTime.Today.AddDays(-30);
        BuildHistoryColumns(HistoryTable, true); BuildHistoryColumns(ProgramHistory, false);
        AddColumn(EventsTable, "Time", nameof(EventRow.Time), 145); AddColumn(EventsTable, "Name", nameof(EventRow.Name), 150);
        AddColumn(EventsTable, "EventTitle", nameof(EventRow.Title), 150); AddColumn(EventsTable, "Detail", nameof(EventRow.Detail));
        SettingsPage.Content = BuildSettings();
        ProgramList.ContextMenuOpening += (_, e) => { e.Handled = true; if (selected is not null) ShowProgramMenu(selected.Id, ProgramList); };
        supervisor.Changed += OnSupervisorChanged;
        WorkbenchTheme.Changed += OnThemeChanged;
        sampler.Tick += async (_, _) => { if (closed) return; RefreshTimedDetails(); Sample(); if (recordsDirty) await GuardAsync(RefreshRecordsAsync); };
        IsVisibleChanged += (_, _) => { if (IsVisible) { sampler.Start(); OnSupervisorChanged(); } else { sampler.Stop(); lastMetrics.Clear(); } };
        SizeChanged += (_, _) => ApplyAdaptiveLayout();
        PreviewKeyDown += OnKey; Closing += OnClosing;
        Closed += (_, _) => { closed = true; sampler.Stop(); supervisor.Changed -= OnSupervisorChanged; WorkbenchTheme.Changed -= OnThemeChanged; logView?.Dispose(); };
        Loaded += async (_, _) => { await GuardAsync(() => WindowPlacement.RestoreAsync(this, store)); await GuardAsync(RefreshRecordsAsync); };
        ready = true; RefreshPrograms(); Navigate("programs");
    }

    private sealed record FilterChoice(string Key, string Label);
    private sealed record EventRow(EventRecord Event, string Name)
    {
        public string Time => Event.At.ToLocalTime().ToString("MM-dd HH:mm:ss", CultureInfo.CurrentUICulture);
        public string Title => Text.Get("Event" + Event.Type);
        public string Detail => Event.Detail;
    }
    private static void AddColumn(DataGrid table, string key, string property, double width = 0) => table.Columns.Add(new DataGridTextColumn
    {
        Header = Text.Get(key), Binding = new Binding(property),
        Width = width == 0 ? new DataGridLength(1, DataGridLengthUnitType.Star) : new DataGridLength(width),
        ElementStyle = new Style(typeof(TextBlock)) { Setters = { new Setter(TextBlock.TextWrappingProperty, TextWrapping.Wrap), new Setter(FrameworkElement.MarginProperty, new Thickness(6, 8, 6, 8)) } }
    });
    private static void BuildHistoryColumns(DataGrid table, bool full)
    {
        AddColumn(table, "Time", nameof(HistoryRow.DisplayTime), full ? 145 : 110);
        if (full) AddColumn(table, "Name", nameof(HistoryRow.ProgramName));
        AddColumn(table, "Outcome", nameof(HistoryRow.DisplayOutcome), full ? 130 : 100);
        if (full) { AddColumn(table, "Duration", nameof(HistoryRow.Duration), 95); AddColumn(table, "Code", nameof(HistoryRow.DisplayCode), 130); }
    }
    public static Button Button(string key, Func<Task> action)
    {
        var button = new Button { Content = Text.Get(key), Margin = new(0, 4, 8, 4) };
        if (Application.Current.TryFindResource("WorkbenchButton") is Style style) button.Style = style;
        button.Click += async (_, _) => { button.IsEnabled = false; try { await RunGuardedAsync(action); } finally { button.IsEnabled = true; } };
        return button;
    }
    public static async Task RunGuardedAsync(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex) { MessageBox.Show(Text.Get("Error") + "\n" + ex.Message, "Barback", MessageBoxButton.OK, MessageBoxImage.Error); }
    }
    public static bool Confirm(string key) => MessageBox.Show(Text.Get(key), "Barback", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) == MessageBoxResult.OK;
    private bool Ask(string message) => MessageBox.Show(this, message, "Barback", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) == MessageBoxResult.OK;
    private async Task GuardAsync(Func<Task> action) { try { await action(); } catch (Exception ex) { ShowError(ex); } }
    private void ShowError(Exception ex) { if (storageBannerShown) dismissedStorageError = supervisor.StorageError; storageBannerShown = false; Message.Tag = null; Message.Text = Text.Get("Error") + "\n" + ex.Message; MessagePanel.Visibility = Visibility.Visible; }
    private void DismissMessage(object sender, RoutedEventArgs e)
    {
        // A dismissed storage error stays hidden until a different one appears.
        if (storageBannerShown) dismissedStorageError = supervisor.StorageError;
        storageBannerShown = false; MessagePanel.Visibility = Visibility.Collapsed;
    }
    private void SyncStorageBanner()
    {
        var storage = supervisor.StorageError;
        if (storage is null) { if (storageBannerShown) { storageBannerShown = false; MessagePanel.Visibility = Visibility.Collapsed; } dismissedStorageError = null; return; }
        if (storage == dismissedStorageError || storageBannerShown && Message.Tag as string == storage) return;
        Message.Text = Text.Format("StorageErrorBanner", storage); Message.Tag = storage; storageBannerShown = true; MessagePanel.Visibility = Visibility.Visible;
    }
    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);

    private void OnSupervisorChanged()
    {
        if (closed || Interlocked.Exchange(ref refreshQueued, 1) != 0) return;
        Dispatcher.BeginInvoke(() => { Interlocked.Exchange(ref refreshQueued, 0); if (closed) return; recordsDirty = true; RefreshPrograms(); }, DispatcherPriority.Background);
    }
    private void OnThemeChanged() { foreach (var row in rows) row.RefreshTheme(); RefreshNavigation(); }
    private bool Matches(object item)
    {
        if (item is not ProgramRow row) return false;
        var query = ready ? SearchBox.Text.Trim() : "";
        return (query.Length == 0 || row.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || row.Group.Contains(query, StringComparison.OrdinalIgnoreCase))
            && (!ready || KindFilter.SelectedIndex < 1 || row.Snapshot.Config.Kind == (KindFilter.SelectedIndex == 1 ? ProgramKind.Service : ProgramKind.Oneshot))
            && (scope == "all" || scope == "attention" && row.Attention || scope == "group:" + row.Snapshot.Config.Group);
    }
    private void RefreshPrograms()
    {
        if (!ready) return;
        var snapshots = supervisor.Snapshot;
        var byId = snapshots.ToDictionary(s => s.Config.Id);
        var existingRows = rows.ToDictionary(r => r.Id);
        var selectedId = selected?.Id;
        bool shapeChanged = snapshots.Count != rows.Count;
        var now = clock.Now;
        refreshing = true;
        {
            foreach (var row in rows.Where(r => !byId.ContainsKey(r.Id)).ToArray()) { rows.Remove(row); shapeChanged = true; }
            foreach (var snapshot in snapshots)
            {
                var row = existingRows.GetValueOrDefault(snapshot.Config.Id);
                if (row is null)
                {
                    row = new(snapshot, PerformPrimaryAsync, id => { ShowProgramMenu(id, Keyboard.FocusedElement as FrameworkElement ?? ProgramList); return Task.CompletedTask; }, ShowError);
                    rows.Add(row); shapeChanged = true;
                }
                else shapeChanged |= row.Name != snapshot.Config.Name || row.Snapshot.Config.Group != snapshot.Config.Group
                    || row.Snapshot.Config.Kind != snapshot.Config.Kind || row.Attention != ProgramActionPolicy.NeedsAttention(snapshot);
                row.Update(snapshot, now);
            }
            if (shapeChanged) programView.Refresh();
        }
        ProgramList.SelectedItem = rows.FirstOrDefault(r => r.Id == selectedId && Matches(r));
        selected = ProgramList.SelectedItem as ProgramRow;
        refreshing = false;
        SyncStorageBanner();
        UpdateSummary(); UpdateGroups(); UpdateEmptyState(); UpdateDetails(); ApplyAdaptiveLayout();
    }
    private void RefreshTimedDetails()
    {
        var now = clock.Now;
        foreach (var row in rows.Where(r => r.Snapshot.Runtime.Active || r.Snapshot.Runtime.Phase == Phase.Backoff)) row.Update(row.Snapshot, now);
        UpdateDetails();
    }
    private void UpdateSummary()
    {
        if (page != "programs" || editor is not null) return;
        var running = rows.Count(r => r.Snapshot.Runtime.Phase == Phase.Running);
        var retry = rows.Count(r => r.Snapshot.Runtime.Phase == Phase.Backoff);
        var attention = rows.Count(r => r.Attention);
        Summary.Text = Text.Format("ProgramSummary", running, retry, attention, rows.Count);
        AttentionCount.Text = attention == 0 ? "" : attention.ToString(CultureInfo.CurrentUICulture);
        BatchButton.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
    private void UpdateGroups()
    {
        var groups = rows.Where(r => !string.IsNullOrWhiteSpace(r.Snapshot.Config.Group)).GroupBy(r => r.Snapshot.Config.Group).OrderBy(g => g.Key).ToArray();
        var signature = string.Join('|', groups.Select(g => g.Key + ":" + g.Count()));
        if (signature == groupSignature) return; groupSignature = signature;
        GroupsNav.Children.Clear();
        foreach (var group in groups)
        {
            var button = new Button { Content = group.Key + "  " + group.Count(), Tag = "group:" + group.Key, Style = (Style)FindResource("NavButton"), ToolTip = group.Key };
            button.Click += NavigateClick; GroupsNav.Children.Add(button);
        }
        RefreshNavigation();
    }
    private void UpdateEmptyState()
    {
        bool empty = programView.IsEmpty;
        ProgramList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        bool first = rows.Count == 0;
        EmptyHeading.Text = Text.Get(first ? "EmptyHeading" : scope == "attention" ? "NothingToResolve" : "NoMatches");
        EmptyDescription.Text = Text.Get(first ? "EmptyDescription" : scope == "attention" ? "NothingToResolveHint" : "NoMatchesHint");
        EmptyAdd.Visibility = first ? Visibility.Visible : Visibility.Collapsed; EmptyImport.Visibility = EmptyAdd.Visibility;
        ClearFilter.Visibility = first ? Visibility.Collapsed : Visibility.Visible;
    }
    private void ApplyFilter()
    {
        if (!ready) return;
        refreshing = true; var id = selected?.Id; programView.Refresh();
        ProgramList.SelectedItem = rows.FirstOrDefault(r => r.Id == id && Matches(r)); selected = ProgramList.SelectedItem as ProgramRow;
        refreshing = false; historical = null; UpdateEmptyState(); UpdateDetails(); ApplyAdaptiveLayout();
    }
    private void SearchChanged(object sender, TextChangedEventArgs e) => ApplyFilter();
    private void FilterChanged(object sender, SelectionChangedEventArgs e) => ApplyFilter();
    private void ClearFilterClick(object sender, RoutedEventArgs e) { scope = "all"; SearchBox.Clear(); KindFilter.SelectedIndex = 0; Navigate("programs"); ApplyFilter(); }

    private async void NavigateClick(object sender, RoutedEventArgs e)
    {
        var target = (string)((Button)sender).Tag;
        if (!await RequestLeaveEditorAsync()) return;
        if (target == "attention" || target.StartsWith("group:", StringComparison.Ordinal)) { scope = target; Navigate("programs"); ApplyFilter(); }
        else { if (target == "programs") scope = "all"; Navigate(target); ApplyFilter(); }
        if (target == "activity") await GuardAsync(RefreshRecordsAsync);
    }
    private void Navigate(string target)
    {
        page = target; historical = null;
        Workbench.Visibility = target == "programs" ? Visibility.Visible : Visibility.Collapsed;
        ActivityPage.Visibility = target == "activity" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = target == "settings" ? Visibility.Visible : Visibility.Collapsed;
        EditorHost.Visibility = Visibility.Collapsed; PageActions.Visibility = target == "programs" ? Visibility.Visible : Visibility.Collapsed;
        PageTitle.Text = Text.Get(target == "activity" ? "Activity" : target == "settings" ? "Settings" : scope == "attention" ? "Attention" : "Programs");
        if (scope.StartsWith("group:", StringComparison.Ordinal) && target == "programs") PageTitle.Text = scope[6..];
        Summary.Text = Text.Get(target == "activity" ? "ActivityHint" : target == "settings" ? "SettingsHint" : "");
        UpdateSummary(); RefreshNavigation(); ApplyAdaptiveLayout();
    }
    private void RefreshNavigation()
    {
        foreach (var button in new[] { ProgramsNav, ActivityNav, SettingsNav, AttentionNav }.Concat(GroupsNav.Children.OfType<Button>()))
        {
            var target = (string)button.Tag;
            bool current = target == "programs" ? page == "programs" && scope == "all" : target == "activity" || target == "settings" ? page == target : page == "programs" && scope == target;
            button.Background = current ? Brush("SelectedBrush") : Brushes.Transparent;
            button.FontWeight = current ? FontWeights.SemiBold : FontWeights.Normal;
        }
    }
    public void SelectProgram(Guid? id)
    {
        if (editor is not null) { _ = SelectAfterEditorAsync(id); return; }
        scope = "all"; SearchBox.Clear(); KindFilter.SelectedIndex = 0; Navigate("programs"); ApplyFilter();
        if (id is Guid value) ProgramList.SelectedItem = rows.FirstOrDefault(r => r.Id == value);
    }
    private async Task SelectAfterEditorAsync(Guid? id) { if (await RequestLeaveEditorAsync()) SelectProgram(id); }
    public async void ShowPage(int index)
    {
        if (!await RequestLeaveEditorAsync()) return;
        if (Application.Current is App application) application.OpenMain(); else { Show(); Activate(); }
        if (index == 0) { scope = "all"; Navigate("programs"); ApplyFilter(); }
        else if (index == 3) Navigate("settings");
        else { Navigate("activity"); ActivityTabs.SelectedIndex = index == 2 ? 1 : 0; await GuardAsync(RefreshRecordsAsync); }
    }
    private async void ProgramSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || refreshing || e.Source != ProgramList) return;
        selected = ProgramList.SelectedItem as ProgramRow; historical = null; narrowDetail = selected is not null;
        ClearLog(); Metrics.Text = ""; UpdateDetails(); UpdateProgramHistory(); ApplyAdaptiveLayout();
        await GuardAsync(RefreshRecordsAsync);
    }
    private void ProgramDoubleClick(object sender, MouseButtonEventArgs e) { if (selected is not null && e.OriginalSource is not System.Windows.Controls.Button) { narrowDetail = true; ApplyAdaptiveLayout(); } }
    private void ProgramKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && selected is not null && e.OriginalSource is not System.Windows.Controls.Button) { narrowDetail = true; ApplyAdaptiveLayout(); e.Handled = true; }
        if (e.Key == Key.F10 && Keyboard.Modifiers == ModifierKeys.Shift && selected is not null) { ShowProgramMenu(selected.Id, ProgramList); e.Handled = true; }
    }
    private void ApplyAdaptiveLayout()
    {
        if (!ready) return;
        bool narrow = ActualWidth < 1060 || SystemParameters.HighContrast && ActualWidth < 1200;
        RailColumn.Width = new GridLength(narrow ? 156 : 176);
        if (narrow)
        {
            ListColumn.Width = new GridLength(1, GridUnitType.Star); DividerColumn.Width = new GridLength(0); DetailColumn.Width = new GridLength(0);
            bool detail = narrowDetail && (selected is not null || historical is not null);
            CollectionPane.Visibility = detail ? Visibility.Collapsed : Visibility.Visible;
            DetailPane.Visibility = detail ? Visibility.Visible : Visibility.Collapsed;
            Grid.SetColumn(DetailPane, 0); Grid.SetColumnSpan(DetailPane, 3); WorkbenchDivider.Visibility = Visibility.Collapsed;
        }
        else
        {
            ListColumn.Width = new GridLength(1, GridUnitType.Star); DividerColumn.Width = new GridLength(1); DetailColumn.Width = new GridLength(360);
            CollectionPane.Visibility = Visibility.Visible; DetailPane.Visibility = Visibility.Visible;
            Grid.SetColumn(DetailPane, 2); Grid.SetColumnSpan(DetailPane, 1); WorkbenchDivider.Visibility = Visibility.Visible;
        }
        BackToList.Visibility = narrow || historical is not null ? Visibility.Visible : Visibility.Collapsed;
    }
    private void BackClick(object sender, RoutedEventArgs e)
    {
        if (historical is not null && historyFromActivity) { Navigate("activity"); return; }
        historical = null; narrowDetail = false; ClearLog(); UpdateDetails(); ApplyAdaptiveLayout();
    }

    private void UpdateDetails()
    {
        if (!ready) return;
        var snapshot = selected?.Snapshot;
        if (historical is not null) snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == historical.ProgramId);
        bool exists = snapshot is not null || historical is not null;
        NoSelection.Visibility = exists ? Visibility.Collapsed : Visibility.Visible; SelectedDetail.Visibility = exists ? Visibility.Visible : Visibility.Collapsed;
        if (!exists) { ClearLog(); return; }
        DetailName.Text = historical?.ProgramName ?? snapshot!.Config.Name;
        DetailStatus.Text = historical is not null ? Text.Get("ExecutionRecord") + " · " + historical.DisplayOutcome : selected!.Status + " · " + selected.Kind;
        RestartButton.Visibility = historical is null && snapshot is not null && ProgramActionPolicy.CanRestart(snapshot) ? Visibility.Visible : Visibility.Collapsed;
        FailurePanel.Visibility = historical is null && snapshot is not null && ProgramActionPolicy.NeedsAttention(snapshot) ? Visibility.Visible : Visibility.Collapsed;
        FailureText.Text = snapshot?.Runtime.Error ?? Text.Get(snapshot?.Runtime.CleanupFailed == true ? "CleanupFailedHint" : "FailureHint");
        bool pending = historical is null && snapshot is not null && ProgramActionPolicy.HasPendingConfiguration(snapshot);
        PendingPanel.Visibility = pending ? Visibility.Visible : Visibility.Collapsed;
        PendingText.Text = Text.Get("Pending");
        ConfigDescription.Text = snapshot is null ? Text.Get("DeletedProgram") : ConfigurationSummary(snapshot.Config);
        if (historical is not null) ConfigDescription.Text = Text.Format("HistoryConfigHint", historical.Run.ConfigVersion) + "\n\n" + ConfigDescription.Text;
        RerunButton.Visibility = historical is not null && snapshot?.Config.Kind == ProgramKind.Oneshot ? Visibility.Visible : Visibility.Collapsed;
        RerunButton.IsEnabled = historical is not null && ProgramActionPolicy.CanRerun(historical.Run, snapshot);
        RerunButton.ToolTip = RerunButton.IsEnabled ? Text.Get("RerunCurrent") : Text.Get("RerunUnavailable");
        var run = historical?.Run ?? (snapshot?.Runtime.RunId is Guid runId ? loadedRuns.FirstOrDefault(r => r.Id == runId) : loadedRuns.FirstOrDefault(r => r.ProgramId == snapshot?.Config.Id));
        RunDescription.Text = run is null ? Text.Get(snapshot?.Runtime.Active == true ? "PreparingOutput" : "NoOutput")
            : Text.Format("RunDescription", run.Started.ToLocalTime().ToString("MM-dd HH:mm:ss", CultureInfo.CurrentUICulture), run.ConfigVersion, historical?.DisplayCode ?? (run.Ended is null ? Text.Get("RunInProgress") : new HistoryRow(run, "").DisplayOutcome));
        if (run?.Id != displayedRun)
        {
            ClearLog(); displayedRun = run?.Id;
            if (run?.LogDirectory is string directory)
            {
                var encoding = (historical is null ? snapshot?.RunConfig : null)?.Launch.EncodingCodePage ?? snapshot?.Config.Launch.EncodingCodePage ?? 65001;
                logView = new(directory, encoding) { OpenSeparate = () => OpenLogWindow(run, encoding) };
                LogHost.Content = logView;
            }
        }
        if (logView is null) LogHost.Content = new TextBlock { Text = Text.Get("NoOutput"), Style = (Style)FindResource("Caption"), Margin = new(0, 16, 0, 0) };
        if (historical is not null || snapshot?.Runtime.Active != true) Metrics.Text = "";
    }
    private static string ConfigurationSummary(ProgramConfig config)
    {
        var launch = config.Launch;
        return Text.Get("Mode") + "\n" + Text.Option(launch.Mode) + "\n\n" + Text.Get("Executable") + "\n" + launch.Executable
            + "\n\n" + Text.Get("Arguments") + "\n" + string.Join("\n", launch.Arguments)
            + (launch.RawArguments is null ? "" : "\n" + launch.RawArguments)
            + (launch.Mode == ExecutionMode.PowerShellFile ? "\n\n" + Text.Get("ScriptPath") + "\n" + launch.ScriptPath : "")
            + (launch.Mode is ExecutionMode.Cmd or ExecutionMode.PowerShellText ? "\n\n" + Text.Get("ScriptText") + "\n" + launch.ScriptText : "")
            + "\n\n" + Text.Get("WorkingDirectory") + "\n" + launch.WorkingDirectory
            + "\n\n" + Text.Get("ConfigVersion") + "\nv" + config.Version
            + "\n\n" + Text.Get("Enabled") + " · " + Text.Get(config.Enabled ? "Yes" : "No")
            + (config.Kind == ProgramKind.Service ? "\n" + Text.Get("Autostart") + " · " + Text.Get(config.Policy.Autostart ? "Yes" : "No") + "\n" + Text.Option(config.Policy.Restart) : "")
            + "\n\n" + Text.Get("StopMode") + "\n" + Text.Option(launch.StopMode)
            + (config.Notes.Length == 0 ? "" : "\n\n" + Text.Get("Notes") + "\n" + config.Notes);
    }
    private void ClearLog() { logView?.Dispose(); logView = null; LogHost.Content = null; displayedRun = null; }
    private void Sample()
    {
        if (!IsVisible || page != "programs" || historical is not null || selected is null) return;
        var snapshot = selected.Snapshot;
        if (snapshot.Runtime.Pid is not int pid || !snapshot.Runtime.Active) { Metrics.Text = ""; return; }
        try
        {
            using var process = Process.GetProcessById(pid);
            if (snapshot.Runtime.CreationTime is not long identity || process.StartTime.ToFileTimeUtc() != identity) { Metrics.Text = Text.Get("Metrics") + " · " + Text.Get("Unavailable"); return; }
            var cpu = process.TotalProcessorTime; var now = DateTime.UtcNow;
            var percent = lastMetrics.TryGetValue(snapshot.Config.Id, out var old) && now > old.At ? Math.Clamp((cpu - old.Cpu).TotalSeconds / (now - old.At).TotalSeconds / Environment.ProcessorCount * 100, 0, 100).ToString("F1", CultureInfo.CurrentUICulture) + "%" : "—";
            lastMetrics[snapshot.Config.Id] = (cpu, now);
            Metrics.Text = Text.Format("ProcessMetrics", pid, percent, (process.WorkingSet64 / 1048576d).ToString("F1", CultureInfo.CurrentUICulture));
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Win32Exception) { Metrics.Text = Text.Get("Metrics") + " · " + Text.Get("Unavailable"); }
    }

    public async Task PerformPrimaryAsync(Guid id)
    {
        var snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id); if (snapshot is null) return;
        var action = ProgramActionPolicy.Primary(snapshot); if (action.Signal is not Signal signal) return;
        if (action.Confirm && !Ask(Text.Get("InterruptedConfirm") + "\n\n" + snapshot.Config.Name)) return;
        var latest = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id);
        if (latest is null || ProgramActionPolicy.Primary(latest).Signal != signal) return;
        await supervisor.SendAsync(id, signal);
    }
    public Task SelectedAsync(Signal signal) => selected is null ? Task.CompletedTask : SendAsync(selected.Id, signal);
    private Task SendAsync(Guid id, Signal signal)
    {
        var snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id);
        if (snapshot is null || signal == Signal.Restart && !ProgramActionPolicy.CanRestart(snapshot)) return Task.CompletedTask;
        return supervisor.SendAsync(id, signal);
    }
    private async void RestartClick(object sender, RoutedEventArgs e) { if (selected is not null) await GuardAsync(() => SendAsync(selected.Id, Signal.Restart)); }
    private void DetailMoreClick(object sender, RoutedEventArgs e) { var id = historical?.ProgramId ?? selected?.Id; if (id is Guid value) ShowProgramMenu(value, (FrameworkElement)sender); }
    public void ShowProgramMenu(Guid id, FrameworkElement target)
    {
        var snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id); if (snapshot is null) return;
        var menu = new ContextMenu { PlacementTarget = target, Placement = PlacementMode.Bottom };
        AddMenu(menu, "Edit", () => EditAsync(snapshot.Config, snapshot.Config.Kind));
        AddMenu(menu, "Copy", () => CopyAsync(id));
        AddMenu(menu, "ProgramRecords", async () => { SelectProgram(id); DetailTabs.SelectedIndex = 2; narrowDetail = true; ApplyAdaptiveLayout(); await RefreshRecordsAsync(); });
        if (ProgramActionPolicy.CanRestart(snapshot)) AddMenu(menu, "Restart", () => SendAsync(id, Signal.Restart));
        if (snapshot.Runtime.Active) AddMenu(menu, "Force", async () => { if (Ask(Text.Get("ForceConfirm") + "\n\n" + snapshot.Config.Name)) { var latest = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id); if (latest?.Runtime.RunId == snapshot.Runtime.RunId) await supervisor.SendAsync(id, Signal.Force); } });
        if (snapshot.Runtime.Phase == Phase.Fatal) AddMenu(menu, "ClearFailure", async () =>
        {
            // An unconfirmed previous process may still be running; clearing it risks a duplicate instance.
            if (snapshot.UnresolvedPid is int pid && !Ask(Text.Format("ClearUnresolvedConfirm", pid, snapshot.Config.Name))) return;
            await supervisor.SendAsync(id, Signal.ClearFailure);
        });
        menu.Items.Add(new Separator()); AddMenu(menu, "Delete", () => DeleteAsync(id)); menu.IsOpen = true;
    }
    private void AddMenu(ContextMenu menu, string key, Func<Task> action, bool enabled = true)
    {
        var item = new MenuItem { Header = Text.Get(key), IsEnabled = enabled };
        item.Click += async (_, _) => await GuardAsync(action); menu.Items.Add(item);
    }
    private void AddClick(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = (FrameworkElement)sender, Placement = PlacementMode.Bottom };
        AddMenu(menu, "AddService", () => EditAsync(null, ProgramKind.Service)); AddMenu(menu, "AddOneshot", () => EditAsync(null, ProgramKind.Oneshot)); menu.IsOpen = true;
    }
    private void BatchClick(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = BatchButton, Placement = PlacementMode.Bottom };
        AddMenu(menu, "StartAll", () => supervisor.BatchAsync(Signal.Start), supervisor.Snapshot.Any(s => s.Config.Enabled && s.Config.Kind == ProgramKind.Service && !s.Runtime.Active && s.Runtime.Phase != Phase.Backoff));
        AddMenu(menu, "StopAll", () => BatchAsync(Signal.Stop), supervisor.Snapshot.Any(s => s.Runtime.Active || s.Runtime.Phase == Phase.Backoff));
        AddMenu(menu, "RestartAll", () => BatchAsync(Signal.Restart), supervisor.Snapshot.Any(s => s.Config.Enabled && s.Config.Kind == ProgramKind.Service)); menu.IsOpen = true;
    }
    private async Task BatchAsync(Signal signal)
    {
        var candidates = supervisor.Snapshot.Where(s => signal == Signal.Stop ? s.Runtime.Active || s.Runtime.Phase == Phase.Backoff : s.Config.Enabled && s.Config.Kind == ProgramKind.Service).ToArray();
        if (candidates.Length == 0) return;
        string message = Text.Format(signal == Signal.Stop ? "BatchStopPrompt" : "BatchRestartPrompt", candidates.Count(s => s.Config.Kind == ProgramKind.Service), candidates.Count(s => s.Config.Kind == ProgramKind.Oneshot));
        message += "\n\n" + string.Join("\n", candidates.Take(15).Select(s => s.Config.Name)) + (candidates.Length > 15 ? "\n…" : "");
        if (Ask(message)) await supervisor.BatchAsync(signal);
    }
    public Task EditSelectedAsync()
    {
        var id = historical?.ProgramId ?? selected?.Id;
        var config = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id)?.Config;
        return config is null ? Task.CompletedTask : EditAsync(config, config.Kind);
    }
    public async Task EditAsync(ProgramConfig? config, ProgramKind kind)
    {
        if (!await RequestLeaveEditorAsync()) return;
        if (Application.Current is App application) application.OpenMain();
        page = "programs"; historical = null; RefreshNavigation();
        config ??= new() { Kind = kind, Name = "", Launch = new() { WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) }, Policy = new() { Autostart = false } };
        editor = new EditorView(supervisor, config);
        editor.CancelRequested += async (_, _) => { if (await RequestLeaveEditorAsync()) { Navigate("programs"); UpdateDetails(); } };
        EditorHost.Content = editor; EditorHost.Visibility = Visibility.Visible;
        Workbench.Visibility = ActivityPage.Visibility = SettingsPage.Visibility = Visibility.Collapsed; PageActions.Visibility = Visibility.Collapsed;
        PageTitle.Text = Text.Get(config.Version == 0 ? "AddProgram" : "Edit"); Summary.Text = config.Kind == ProgramKind.Service ? Text.Get("ServiceHint") : Text.Get("OneshotHint");
    }
    public async Task<bool> RequestLeaveEditorAsync()
    {
        if (editor is null) return true;
        if (!await editor.RequestLeaveAsync()) return false;
        editor.Dispose(); editor = null; EditorHost.Content = null; EditorHost.Visibility = Visibility.Collapsed; Navigate(page); UpdateDetails(); return true;
    }
    private async void EditClick(object sender, RoutedEventArgs e) => await GuardAsync(EditSelectedAsync);
    private async Task CopyAsync(Guid id)
    {
        var config = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id)?.Config; if (config is null || !Ask(Text.Get("CopyConfirm") + "\n\n" + config.Name)) return;
        string name = config.Name + " " + Text.Get("CopySuffix"); int suffix = 2;
        while (supervisor.Snapshot.Any(s => s.Config.NameKey == name.Trim().Normalize().ToUpperInvariant())) name = config.Name + " " + Text.Get("CopySuffix") + " " + suffix++;
        var copy = config with { Id = Guid.NewGuid(), Version = 0, Name = name, Enabled = false, Policy = config.Policy with { Autostart = false } };
        await supervisor.SaveAsync(copy, 0); await EditAsync(supervisor.Snapshot.First(s => s.Config.Id == copy.Id).Config, copy.Kind);
    }
    private async Task DeleteAsync(Guid id)
    {
        var config = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id)?.Config;
        if (config is not null && Ask(Text.Format("DeleteProgramPrompt", config.Name))) await supervisor.DeleteAsync(id);
    }
    private void ImportClick(object sender, RoutedEventArgs e) => new ImportWindow(supervisor) { Owner = this }.ShowDialog();

    private async Task RefreshRecordsAsync()
    {
        if (loadingRecords || closed) return;
        loadingRecords = true; recordsDirty = false;
        try
        {
            var runs = (await store.RunsAsync()).ToArray();
            if (closed) return;
            if (!loadedRuns.SequenceEqual(runs)) { loadedRuns = runs; FilterHistory(); UpdateProgramHistory(); }
            if (page == "activity" && ActivityTabs.SelectedIndex == 1)
            {
                var events = (await store.EventsAsync()).ToArray(); if (closed) return;
                if (!loadedEvents.SequenceEqual(events)) { loadedEvents = events; FilterEvents(); }
            }
            UpdateDetails();
        }
        catch { recordsDirty = true; throw; }
        finally { loadingRecords = false; }
    }
    private void FilterHistory()
    {
        if (!ready) return;
        var names = supervisor.Snapshot.ToDictionary(s => s.Config.Id, s => s.Config.Name);
        var selectedId = (HistoryTable.SelectedItem as HistoryRow)?.Run.Id;
        string result = (OutcomeFilter.SelectedItem as FilterChoice)?.Key ?? "All";
        var filtered = loadedRuns.Where(r => r.Ended is not null && (HistorySince.SelectedDate is not DateTime since || r.Started.LocalDateTime >= since)
            && (result == "All" || ProgramActionPolicy.Outcome(r) == result))
            .Select(r => new HistoryRow(r, names.GetValueOrDefault(r.ProgramId, Text.Get("DeletedProgram"))))
            .Where(r => r.ProgramName.Contains(HistorySearch.Text.Trim(), StringComparison.OrdinalIgnoreCase)).ToArray();
        HistoryTable.ItemsSource = filtered; HistoryTable.SelectedItem = filtered.FirstOrDefault(r => r.Run.Id == selectedId);
        HistoryHint.Text = filtered.Length == 0 ? Text.Get("NoHistory") : Text.Get("HistoryHint");
    }
    private void UpdateProgramHistory()
    {
        var id = historical?.ProgramId ?? selected?.Id;
        ProgramHistory.ItemsSource = id is null ? null : loadedRuns.Where(r => r.ProgramId == id && r.Ended is not null).Select(r => new HistoryRow(r, DetailName.Text)).ToArray();
    }
    private void FilterEvents()
    {
        if (!ready) return;
        var names = supervisor.Snapshot.ToDictionary(s => s.Config.Id, s => s.Config.Name);
        EventsTable.ItemsSource = loadedEvents.Select(record => new EventRow(record, record.ProgramId is Guid id ? names.GetValueOrDefault(id, Text.Get("DeletedProgram")) : "Barback"))
            .Where(row => (row.Title + " " + row.Name + " " + row.Detail).Contains(EventSearch.Text.Trim(), StringComparison.OrdinalIgnoreCase)).ToArray();
    }
    private void HistoryFilterChanged(object sender, TextChangedEventArgs e) => FilterHistory();
    private void HistoryDateChanged(object? sender, SelectionChangedEventArgs e) => FilterHistory();
    private void HistoryOutcomeChanged(object sender, SelectionChangedEventArgs e) => FilterHistory();
    private void EventFilterChanged(object sender, TextChangedEventArgs e) => FilterEvents();
    private void HistorySelected(object sender, SelectionChangedEventArgs e) { if (ready) HistoryOutput.IsEnabled = HistoryTable.SelectedItem is HistoryRow; }
    private async void ActivityTabChanged(object sender, SelectionChangedEventArgs e) { if (ready && e.Source == ActivityTabs) await GuardAsync(RefreshRecordsAsync); }
    private async void DetailTabChanged(object sender, SelectionChangedEventArgs e) { if (ready && e.Source == DetailTabs) { UpdateProgramHistory(); await GuardAsync(RefreshRecordsAsync); } }
    private void HistoryOpen(object sender, MouseButtonEventArgs e) { if (HistoryTable.SelectedItem is HistoryRow run) OpenHistory(run, true); }
    private void HistoryOutputClick(object sender, RoutedEventArgs e) { if (HistoryTable.SelectedItem is HistoryRow run) OpenHistory(run, true); }
    private void ProgramHistoryOpen(object sender, MouseButtonEventArgs e) { if (ProgramHistory.SelectedItem is HistoryRow run) OpenHistory(run, false); }
    private void HistoryKeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter && ((DataGrid)sender).SelectedItem is HistoryRow run) { OpenHistory(run, sender == HistoryTable); e.Handled = true; } }
    private void OpenHistory(HistoryRow run, bool fromActivity)
    {
        Navigate("programs"); historical = run; historyFromActivity = fromActivity; narrowDetail = true; DetailTabs.SelectedIndex = 0;
        UpdateDetails(); ApplyAdaptiveLayout();
    }
    private async void RerunClick(object sender, RoutedEventArgs e)
    {
        var run = historical;
        if (run is null) return;
        await GuardAsync(async () =>
        {
            var snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == run.ProgramId);
            if (!ProgramActionPolicy.CanRerun(run.Run, snapshot)) return;
            if (!Ask(Text.Format("RerunPrompt", snapshot!.Config.Name, snapshot.Config.Version, run.Run.ConfigVersion, run.DisplayTime))) return;
            snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == run.ProgramId);
            if (!ProgramActionPolicy.CanRerun(run.Run, snapshot)) return;
            await supervisor.SendAsync(run.ProgramId, Signal.Start); SelectProgram(run.ProgramId); DetailTabs.SelectedIndex = 0;
        });
    }
    private void OpenLogWindow(RunRecord run, int encoding)
    {
        if (run.LogDirectory is null) return;
        if (logWindows.TryGetValue(run.Id, out var existing)) { existing.Show(); existing.Activate(); return; }
        var window = new LogWindow(run.LogDirectory, encoding); logWindows[run.Id] = window;
        window.Closed += (_, _) => logWindows.Remove(run.Id); window.Show();
    }

    private UIElement BuildSettings()
    {
        var panel = new StackPanel { Margin = new(24, 0, 24, 24), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Stretch };
        void Heading(string key) => panel.Children.Add(new TextBlock { Text = Text.Get(key), Style = (Style)FindResource("SectionHeading") });
        void Hint(string key) => panel.Children.Add(new TextBlock { Text = Text.Get(key), Style = (Style)FindResource("Caption"), Margin = new(0, 0, 0, 12) });
        Heading("GeneralSettings"); Hint("CloseContinues");
        var close = new CheckBox { Content = Text.Get("CloseExit"), IsChecked = (Application.Current as App)?.CloseExits == true, Margin = new(0, 0, 0, 14) };
        close.Click += async (_, _) => await GuardAsync(async () => { await store.SetSettingAsync("close_exits", close.IsChecked == true ? "true" : "false"); if (Application.Current is App app) app.CloseExits = close.IsChecked == true; }); panel.Children.Add(close);
        var theme = new ComboBox { ItemsSource = new[] { new FilterChoice("System", Text.Get("ThemeSystem")), new FilterChoice("Light", Text.Get("ThemeLight")), new FilterChoice("Dark", Text.Get("ThemeDark")) }, DisplayMemberPath = "Label", SelectedValuePath = "Key", SelectedValue = "System", MaxWidth = 260, HorizontalAlignment = HorizontalAlignment.Left, Margin = new(0, 0, 0, 12) };
        panel.Children.Add(new Label { Content = Text.Get("Theme"), Target = theme }); panel.Children.Add(theme);
        bool themeLoaded = false, loadingTheme = false;
        theme.Loaded += async (_, _) => { if (themeLoaded) return; themeLoaded = true; loadingTheme = true; try { theme.SelectedValue = await store.GetSettingAsync("theme") ?? "System"; } finally { loadingTheme = false; } };
        theme.SelectionChanged += async (_, _) => { if (!ready || loadingTheme) return; var value = (string)theme.SelectedValue; WorkbenchTheme.Set(value); await GuardAsync(() => store.SetSettingAsync("theme", value)); };
        var language = new ComboBox { ItemsSource = new[] { new FilterChoice("zh-Hans", "简体中文"), new FilterChoice("en-US", "English") }, DisplayMemberPath = "Label", SelectedValuePath = "Key", SelectedValue = CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.Ordinal) ? "zh-Hans" : "en-US", MaxWidth = 260, HorizontalAlignment = HorizontalAlignment.Left, Margin = new(0, 0, 0, 12) };
        panel.Children.Add(new Label { Content = Text.Get("Language"), Target = language }); panel.Children.Add(language);
        language.SelectionChanged += async (_, _) => await GuardAsync(() => store.SetSettingAsync("language", (string)language.SelectedValue));
        Heading("Notifications"); Hint("NotificationHint");
        var notifications = new CheckBox { Content = Text.Get("Notifications"), IsChecked = shell.NotificationsEnabled, Margin = new(0, 0, 0, 12) };
        notifications.Click += async (_, _) => await GuardAsync(async () => { await store.SetSettingAsync("notifications", notifications.IsChecked == true ? "true" : "false"); shell.NotificationsEnabled = notifications.IsChecked == true; }); panel.Children.Add(notifications);
        Heading("LoginStartup");
        var startup = new TextBlock { Style = (Style)FindResource("Caption"), Margin = new(0, 0, 0, 10) }; panel.Children.Add(startup);
        startup.Loaded += async (_, _) => await GuardAsync(async () => startup.Text = shell.Packaged ? Text.Get("Startup" + await shell.StartupStateAsync()) : Text.Get("StartupUnavailable"));
        var startupActions = new WrapPanel(); panel.Children.Add(startupActions);
        startupActions.Children.Add(Button("LoginEnable", async () => { await shell.SetStartupAsync(true); startup.Text = await shell.StartupStateAsync(); }));
        startupActions.Children.Add(Button("LoginDisable", async () => { await shell.SetStartupAsync(false); startup.Text = await shell.StartupStateAsync(); }));
        startupActions.Children.Add(Button("LoginSettings", () => { ShellIntegration.Open("ms-settings:startupapps"); return Task.CompletedTask; }));
        foreach (var action in startupActions.Children.OfType<Button>().Take(2)) action.IsEnabled = shell.Packaged;
        Heading("EnvironmentTitle"); Hint("EnvironmentHint");
        panel.Children.Add(Button("EditEnvironment", () => { new EnvironmentWindow(store, host) { Owner = this }.ShowDialog(); return Task.CompletedTask; }));
        panel.Children.Add(Button("RefreshEnvironment", () => { host.RefreshEnvironment(); return Task.CompletedTask; }));
        Heading("DataSettings"); panel.Children.Add(new TextBlock { Text = store.Root, Style = (Style)FindResource("Caption"), Margin = new(0, 0, 0, 8) });
        var dataActions = new WrapPanel(); panel.Children.Add(dataActions);
        dataActions.Children.Add(Button("OpenData", () => { ShellIntegration.Open(store.Root); return Task.CompletedTask; }));
        dataActions.Children.Add(Button("Import", () => { new ImportWindow(supervisor) { Owner = this }.ShowDialog(); return Task.CompletedTask; }));
        dataActions.Children.Add(Button("Backup", async () => { var dialog = new SaveFileDialog { Filter = "SQLite|*.db", FileName = "barback-backup.db" }; if (dialog.ShowDialog(this) == true) await store.BackupDatabaseAsync(dialog.FileName); }));
        dataActions.Children.Add(Button("Export", async () => { var dialog = new SaveFileDialog { Filter = "JSON|*.json", FileName = "barback-config.json" }; if (dialog.ShowDialog(this) == true) await store.ExportPortableAsync(dialog.FileName); }));
        dataActions.Children.Add(Button("Restore", RestoreAsync));
        panel.Children.Add(Button("Diagnostics", async () => { var dialog = new SaveFileDialog { Filter = "ZIP|*.zip", FileName = "barback-diagnostics.zip" }; if (dialog.ShowDialog(this) == true) await shell.DiagnosticsAsync(dialog.FileName, supervisor, store); }));
        panel.Children.Add(Button("Updates", () => { ShellIntegration.Open("https://github.com/oyasmi/barback/releases"); return Task.CompletedTask; }));
        panel.Children.Add(Button("Exit", () => Application.Current is App app ? app.ExitAsync() : Task.CompletedTask));
        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
    private async Task RestoreAsync()
    {
        var dialog = new OpenFileDialog { Filter = "Barback configuration|*.json" }; if (dialog.ShowDialog(this) != true) return;
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(dialog.FileName));
        if (!SqliteStore.AcceptsConfigurationSchema(document.RootElement.GetProperty("schemaVersion").GetInt32()) || document.RootElement.GetProperty("sourcePlatform").GetString() != "windows") throw new InvalidDataException("Unsupported backup format.");
        var encrypted = document.RootElement.TryGetProperty("encryptedSecrets", out var flag) && flag.GetBoolean(); var decrypt = new DpapiProtector();
        var restored = new List<ProgramConfig>();
        foreach (var item in document.RootElement.GetProperty("programs").EnumerateArray())
        {
            var config = item.Deserialize<ProgramConfig>()!;
            var environment = config.Launch.Environment.Select(entry => entry.Sensitive && !entry.Remove ? entry with { Value = encrypted ? decrypt.Unprotect(entry.Value ?? "") : null, NeedsInput = !encrypted || entry.NeedsInput } : entry).ToArray();
            restored.Add(config with { Id = Guid.NewGuid(), Version = 0, Enabled = false, Name = config.Name + " restored", Policy = config.Policy with { Autostart = false }, Launch = config.Launch with { Environment = environment } });
        }
        await supervisor.ImportAsync(restored);
    }
    private async void OnKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.F)
        {
            if (editor is null)
            {
                if (page == "programs" && DetailPane.IsKeyboardFocusWithin && DetailTabs.SelectedIndex == 0 && logView is not null) logView.FocusSearch();
                else (page == "activity" ? ActivityTabs.SelectedIndex == 0 ? HistorySearch : EventSearch : SearchBox).Focus();
                e.Handled = true;
            }
        }
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0 && e.Key == Key.N) { e.Handled = true; await GuardAsync(() => EditAsync(null, (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? ProgramKind.Oneshot : ProgramKind.Service)); }
        if (editor is null && e.OriginalSource is not TextBox && ProgramList.IsKeyboardFocusWithin && selected is not null)
        {
            if (e.Key == Key.D && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; await GuardAsync(() => CopyAsync(selected.Id)); }
            if (e.Key == Key.Delete && Keyboard.Modifiers == ModifierKeys.None) { e.Handled = true; await GuardAsync(() => DeleteAsync(selected.Id)); }
        }
        if (e.Key == Key.Escape && editor is null && page == "programs" && narrowDetail && ActualWidth < 1060) { BackClick(this, e); e.Handled = true; }
    }
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (Application.Current is not App application || application.IsExiting) return;
        e.Cancel = true;
        if (closing) return; closing = true;
        try
        {
            if (!await RequestLeaveEditorAsync()) return;
            if (application.CloseExits) { await application.ExitAsync(); return; }
            if (!hiddenHint && await store.GetSettingAsync("hidden_hint") != "true") { MessageBox.Show(this, Text.Get("Hidden"), "Barback"); hiddenHint = true; await store.SetSettingAsync("hidden_hint", "true"); }
            await GuardAsync(() => WindowPlacement.SaveAsync(this, store)); Hide();
        }
        catch (Exception ex) { ShowError(ex); }
        finally { closing = false; }
    }
}
