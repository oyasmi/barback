using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using System.Collections.ObjectModel;
using System.Windows.Data;
using System.Windows.Controls.Primitives;
using Barback.Core;
using Forms = System.Windows.Forms;
namespace Barback.App;

public sealed class TrayAdapter : IDisposable
{
    private readonly Forms.NotifyIcon icon;
    private readonly System.Drawing.Icon brand;
    private readonly TrayIcons badges;
    private TrayState? shownState;
    private readonly MainWindow main;
    private readonly Supervisor supervisor;
    private readonly Window panel;
    private readonly ListBox list = new() { Margin = new(12), BorderThickness = new(0) };
    private readonly ObservableCollection<ProgramRow> rows = [];
    private readonly TextBlock summary = new() { Margin = new(16, 14, 16, 0) };
    private readonly Windows.WindowsClock clock = new();
    private ContextMenu? programMenu;
    private readonly TextBox search = new() { Margin = new(12) };
    private readonly System.Windows.Threading.DispatcherTimer clickTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly HwndSource source;
    private readonly uint taskbarCreated;
    private bool disposed;
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string text);
    public TrayAdapter(MainWindow main, Supervisor supervisor, Func<Task> exit)
    {
        this.main = main; this.supervisor = supervisor;
        var menu = new Forms.ContextMenuStrip(); menu.Items.Add(Text.Get("OpenWorkbench"), null, (_, _) => Application.Current.Dispatcher.BeginInvoke(() => ((App)Application.Current).OpenMain()));
        menu.Items.Add(Text.Get("AddService"), null, async (_, _) => await main.EditAsync(null, ProgramKind.Service));
        menu.Items.Add(Text.Get("AddOneshot"), null, async (_, _) => await main.EditAsync(null, ProgramKind.Oneshot));
        menu.Items.Add(Text.Get("Activity"), null, (_, _) => main.ShowPage(1)); menu.Items.Add(Text.Get("Settings"), null, (_, _) => main.ShowPage(3));
        menu.Items.Add(Text.Get("Exit"), null, async (_, _) => await exit());
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "Barback.ico");
        brand = File.Exists(iconPath) ? new System.Drawing.Icon(iconPath) : (System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
        badges = new(brand);
        icon = new() { Icon = brand, Text = "Barback", Visible = true, ContextMenuStrip = menu };
        panel = new Window { Title = "Barback", Width = 460, MaxHeight = SystemParameters.WorkArea.Height * 0.7, SizeToContent = SizeToContent.Height, ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, WindowStyle = WindowStyle.ToolWindow, Topmost = true };
        panel.SetResourceReference(Window.BackgroundProperty, "SurfaceBrush"); panel.SetResourceReference(Window.ForegroundProperty, "PrimaryTextBrush");
        var root = new DockPanel(); root.SetResourceReference(Panel.BackgroundProperty, "SurfaceBrush"); panel.Content = root;
        var open = MainWindow.Button("OpenWorkbench", () => { panel.Hide(); main.ShowPage(0); return Task.CompletedTask; });
        open.Margin = new(16, 8, 16, 16); DockPanel.SetDock(open, Dock.Bottom); root.Children.Add(open);
        summary.Style = (Style)Application.Current.FindResource("Caption"); DockPanel.SetDock(summary, Dock.Top); root.Children.Add(summary);
        search.Style = (Style)Application.Current.FindResource("WorkbenchInput"); search.ToolTip = Text.Get("Search");
        search.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("Search"));
        list.SetResourceReference(Control.BackgroundProperty, "SurfaceBrush");
        list.ItemTemplate = ((ListBox)main.FindName("ProgramList")).ItemTemplate;
        list.ItemContainerStyle = (Style)Application.Current.FindResource("ProgramItem");
        list.SetValue(VirtualizingPanel.IsVirtualizingProperty, true); list.SetValue(VirtualizingPanel.VirtualizationModeProperty, VirtualizationMode.Recycling);
        list.SetValue(ScrollViewer.HorizontalScrollBarVisibilityProperty, ScrollBarVisibility.Disabled);
        list.ItemsSource = CollectionViewSource.GetDefaultView(rows);
        CollectionViewSource.GetDefaultView(rows).Filter = item => item is ProgramRow row && (row.Name + " " + row.Group).Contains(search.Text.Trim(), StringComparison.OrdinalIgnoreCase);
        DockPanel.SetDock(search, Dock.Top); root.Children.Add(search); root.Children.Add(list);
        search.TextChanged += (_, _) => Refresh(); panel.Deactivated += (_, _) => panel.Dispatcher.BeginInvoke(() => { if (programMenu?.IsOpen != true && !panel.IsActive) panel.Hide(); }); panel.KeyDown += (_, e) => { if (e.Key == Key.Escape) panel.Hide(); }; panel.Closing += (_, e) => { if (!disposed) { e.Cancel = true; panel.Hide(); } };
        list.MouseDoubleClick += (_, _) => OpenSelected(); list.KeyDown += (_, e) => { if (e.Key == Key.Enter) { OpenSelected(); e.Handled = true; } };
        clickTimer.Tick += (_, _) => { clickTimer.Stop(); if (panel.IsVisible) panel.Hide(); else ShowPanel(); };
        icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) clickTimer.Start(); };
        icon.MouseDoubleClick += (_, e) => { if (e.Button != Forms.MouseButtons.Left) return; clickTimer.Stop(); panel.Hide(); ((App)Application.Current).OpenMain(); };
        source = new HwndSource(new HwndSourceParameters("BarbackShellMessages") { Width = 0, Height = 0, WindowStyle = 0 });
        taskbarCreated = RegisterWindowMessage("TaskbarCreated"); source.AddHook(Hook);
        supervisor.Changed += OnChanged;
        WorkbenchTheme.Changed += ThemeChanged;
        OnChanged();
    }
    private nint Hook(nint hwnd, int msg, nint w, nint l, ref bool handled) { if ((uint)msg == taskbarCreated) { icon.Visible = false; icon.Visible = true; } return 0; }
    private void OnChanged() => Application.Current.Dispatcher.BeginInvoke(() =>
    {
        if (disposed) return;
        var snapshots = supervisor.Snapshot;
        var count = snapshots.Count(s => s.Runtime.Active); var errors = snapshots.Count(ProgramActionPolicy.NeedsAttention);
        // Busy covers what is waiting on time or cleanup (stopping, retry pending); a normal start is too brief to flag.
        var state = errors > 0 ? TrayState.Attention : snapshots.Any(s => s.Runtime.Phase is Phase.Stopping or Phase.Backoff || s.Runtime.Cleaning) ? TrayState.Busy : TrayState.Normal;
        SetIcon(state);
        var tip = Text.Format("TraySummary", count, errors); icon.Text = tip.Length > 127 ? tip[..127] : tip; // the shell rejects longer tips
        if (panel.IsVisible) Refresh();
    });
    /// <summary>Only touches the shell when the state changes; re-assigning the same icon still makes the shell redraw it.</summary>
    private void SetIcon(TrayState state, bool force = false)
    {
        if (shownState == state && !force) return;
        shownState = state; icon.Icon = badges.For(state);
    }
    private void ThemeChanged() { foreach (var row in rows) row.RefreshTheme(); badges.Rebuild(); if (shownState is TrayState state) SetIcon(state, force: true); }
    private void Refresh()
    {
        var snapshots = supervisor.Snapshot;
        foreach (var row in rows.Where(r => !snapshots.Any(s => s.Config.Id == r.Id)).ToArray()) rows.Remove(row);
        foreach (var snapshot in snapshots)
        {
            var row = rows.FirstOrDefault(r => r.Id == snapshot.Config.Id);
            if (row is null) { row = new(snapshot, main.PerformPrimaryAsync, ShowMenuAsync, ex => { panel.Hide(); main.ShowPage(0); Dialog.Notify(Text.Get("Error") + "\n\n" + ex.Message, DialogTone.Error, main); }); rows.Add(row); }
            row.Update(snapshot, clock.Now);
        }
        CollectionViewSource.GetDefaultView(rows).Refresh();
        summary.Text = snapshots.Count == 0 ? Text.Get("TrayEmpty") : Text.Format("TraySummary", snapshots.Count(s => s.Runtime.Active), snapshots.Count(ProgramActionPolicy.NeedsAttention));
    }
    private void OpenSelected() { if (list.SelectedItem is not ProgramRow row) return; panel.Hide(); main.ShowPage(0); main.SelectProgram(row.Id); }
    private Task ShowMenuAsync(Guid id)
    {
        programMenu = new() { PlacementTarget = Keyboard.FocusedElement as FrameworkElement ?? list, Placement = PlacementMode.Bottom };
        void Item(string key, Func<Task> action) { var item = new MenuItem { Header = Text.Get(key) }; item.Click += async (_, _) => { panel.Hide(); await MainWindow.RunGuardedAsync(action); }; programMenu.Items.Add(item); }
        Item("Output", () => { main.ShowPage(0); main.SelectProgram(id); return Task.CompletedTask; });
        Item("Edit", () => { var config = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id)?.Config; return config is null ? Task.CompletedTask : main.EditAsync(config, config.Kind); });
        var snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id);
        if (snapshot is not null && ProgramActionPolicy.CanRestart(snapshot)) Item("Restart", () => { var latest = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == id); return latest is not null && ProgramActionPolicy.CanRestart(latest) ? supervisor.SendAsync(id, Signal.Restart) : Task.CompletedTask; });
        programMenu.Closed += (_, _) => panel.Dispatcher.BeginInvoke(() => { if (!panel.IsActive) panel.Hide(); });
        programMenu.IsOpen = true; return Task.CompletedTask;
    }
    private void ShowPanel()
    {
        Refresh();
        var cursor = Forms.Cursor.Position; var handle = new WindowInteropHelper(panel).EnsureHandle(); var screen = Forms.Screen.FromPoint(cursor).WorkingArea;
        SetWindowPos(handle, -1, cursor.X, cursor.Y, 0, 0, 0x11); // establish destination monitor before measuring DIP layout
        double dpi = Math.Max(96, GetDpiForWindow(handle)) / 96d;
        panel.Width = Math.Min(460, screen.Width / dpi); panel.MaxHeight = screen.Height / dpi * 0.7; list.MaxHeight = screen.Height / dpi * 0.7 - 170;
        panel.Show(); panel.UpdateLayout();
        int width = (int)Math.Ceiling(panel.ActualWidth * dpi), height = (int)Math.Ceiling(panel.ActualHeight * dpi);
        int x = Math.Clamp(cursor.X - width / 2, screen.Left, Math.Max(screen.Left, screen.Right - width));
        int y = Math.Clamp(cursor.Y - height, screen.Top, Math.Max(screen.Top, screen.Bottom - height));
        SetWindowPos(handle, -1, x, y, width, height, 0x10); panel.Activate(); search.Focus();
    }
    public void Dispose() { if (disposed) return; disposed = true; clickTimer.Stop(); supervisor.Changed -= OnChanged; WorkbenchTheme.Changed -= ThemeChanged; icon.Visible = false; icon.Dispose(); badges.Dispose(); brand.Dispose(); source.Dispose(); panel.Close(); }
}
