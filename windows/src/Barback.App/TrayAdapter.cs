using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using Barback.Core;
using Forms = System.Windows.Forms;
namespace Barback.App;

public sealed class TrayAdapter : IDisposable
{
    private sealed record TrayRow(Guid Id, string Name);
    private readonly Forms.NotifyIcon icon;
    private readonly System.Drawing.Icon brand;
    private readonly MainWindow main;
    private readonly Supervisor supervisor;
    private readonly Window panel;
    private readonly ListBox list = new() { Margin = new(12), DisplayMemberPath = "Name" };
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
        var menu = new Forms.ContextMenuStrip(); menu.Items.Add(Text.Get("Programs"), null, (_, _) => Application.Current.Dispatcher.BeginInvoke(() => ((App)Application.Current).OpenMain()));
        menu.Items.Add(Text.Get("AddService"), null, async (_, _) => await main.EditAsync(null, ProgramKind.Service));
        menu.Items.Add(Text.Get("AddOneshot"), null, async (_, _) => await main.EditAsync(null, ProgramKind.Oneshot));
        menu.Items.Add(Text.Get("History"), null, (_, _) => main.ShowPage(1)); menu.Items.Add(Text.Get("Events"), null, (_, _) => main.ShowPage(2)); menu.Items.Add(Text.Get("Settings"), null, (_, _) => main.ShowPage(3));
        menu.Items.Add(Text.Get("Exit"), null, async (_, _) => await exit());
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "Barback.ico");
        brand = File.Exists(iconPath) ? new System.Drawing.Icon(iconPath) : (System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
        icon = new() { Icon = brand, Text = "Barback", Visible = true, ContextMenuStrip = menu };
        panel = new Window { Title = "Barback", Width = 440, MaxHeight = SystemParameters.WorkArea.Height * 0.7, SizeToContent = SizeToContent.Height, ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, WindowStyle = WindowStyle.ToolWindow, Topmost = true };
        var root = new DockPanel(); panel.Content = root; var buttons = new WrapPanel(); DockPanel.SetDock(buttons, Dock.Bottom); root.Children.Add(buttons);
        buttons.Children.Add(MainWindow.Button("Programs", () => { panel.Hide(); ((App)Application.Current).OpenMain(); return Task.CompletedTask; }));
        buttons.Children.Add(MainWindow.Button("Start", () => SendAsync(Signal.Start))); buttons.Children.Add(MainWindow.Button("Stop", () => SendAsync(Signal.Stop))); buttons.Children.Add(MainWindow.Button("Restart", () => SendAsync(Signal.Restart)));
        DockPanel.SetDock(search, Dock.Top); root.Children.Add(search); root.Children.Add(new ScrollViewer { Content = list, MaxHeight = SystemParameters.WorkArea.Height * 0.5 });
        search.TextChanged += (_, _) => Refresh(); panel.Deactivated += (_, _) => panel.Hide(); panel.KeyDown += (_, e) => { if (e.Key == Key.Escape) panel.Hide(); }; panel.Closing += (_, e) => { e.Cancel = true; panel.Hide(); };
        list.MouseDoubleClick += (_, _) => OpenSelected(); list.KeyDown += (_, e) => { if (e.Key == Key.Enter) { OpenSelected(); e.Handled = true; } };
        clickTimer.Tick += (_, _) => { clickTimer.Stop(); if (panel.IsVisible) panel.Hide(); else ShowPanel(); };
        icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) clickTimer.Start(); };
        icon.MouseDoubleClick += (_, e) => { if (e.Button != Forms.MouseButtons.Left) return; clickTimer.Stop(); panel.Hide(); ((App)Application.Current).OpenMain(); };
        source = new HwndSource(new HwndSourceParameters("BarbackShellMessages") { Width = 0, Height = 0, WindowStyle = 0 });
        taskbarCreated = RegisterWindowMessage("TaskbarCreated"); source.AddHook(Hook);
        supervisor.Changed += OnChanged;
    }
    private nint Hook(nint hwnd, int msg, nint w, nint l, ref bool handled) { if ((uint)msg == taskbarCreated) { icon.Visible = false; icon.Visible = true; } return 0; }
    private void OnChanged() => Application.Current.Dispatcher.BeginInvoke(() => { var count = supervisor.Snapshot.Count(s => s.Runtime.Active); var errors = supervisor.Snapshot.Count(s => s.Runtime.Phase == Phase.Fatal || s.Runtime.CleanupFailed); icon.Icon = errors > 0 ? System.Drawing.SystemIcons.Warning : supervisor.Snapshot.Any(s => s.Runtime.Phase == Phase.Stopping) ? System.Drawing.SystemIcons.Information : brand; icon.Text = $"Barback: {count} running, {errors} attention"; if (panel.IsVisible) Refresh(); });
    private void Refresh()
    {
        var selected = (list.SelectedItem as TrayRow)?.Id;
        var rows = supervisor.Snapshot.Where(x => x.Config.Name.Contains(search.Text, StringComparison.OrdinalIgnoreCase)).Select(x => new TrayRow(x.Config.Id, x.Config.Name + " — " + Text.Status(x.Runtime.Phase))).ToArray();
        list.ItemsSource = rows; list.SelectedItem = rows.FirstOrDefault(r => r.Id == selected);
    }
    private void OpenSelected() { if (list.SelectedItem is not TrayRow row) return; panel.Hide(); ((App)Application.Current).OpenMain(); main.SelectProgram(row.Id); }
    private Task SendAsync(Signal signal) => list.SelectedItem is TrayRow row ? supervisor.SendAsync(row.Id, signal) : Task.CompletedTask;
    private void ShowPanel()
    {
        Refresh();
        var cursor = Forms.Cursor.Position; var handle = new WindowInteropHelper(panel).EnsureHandle(); var screen = Forms.Screen.FromPoint(cursor).WorkingArea;
        SetWindowPos(handle, -1, cursor.X, cursor.Y, 0, 0, 0x11); // establish destination monitor before measuring DIP layout
        double dpi = Math.Max(96, GetDpiForWindow(handle)) / 96d;
        panel.Width = Math.Min(440, screen.Width / dpi); panel.MaxHeight = screen.Height / dpi * 0.7;
        panel.Show(); panel.UpdateLayout();
        int width = (int)Math.Ceiling(panel.ActualWidth * dpi), height = (int)Math.Ceiling(panel.ActualHeight * dpi);
        int x = Math.Clamp(cursor.X - width / 2, screen.Left, Math.Max(screen.Left, screen.Right - width));
        int y = Math.Clamp(cursor.Y - height, screen.Top, Math.Max(screen.Top, screen.Bottom - height));
        SetWindowPos(handle, -1, x, y, width, height, 0x10); panel.Activate(); search.Focus();
    }
    public void Dispose() { if (disposed) return; disposed = true; clickTimer.Stop(); supervisor.Changed -= OnChanged; icon.Visible = false; icon.Dispose(); brand.Dispose(); source.Dispose(); panel.Hide(); }
}
