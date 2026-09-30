using System.Diagnostics;
using System.Windows.Threading;
using Barback.Core;
namespace Barback.App;

public sealed class ExitProgressWindow : Window
{
    private readonly Supervisor supervisor;
    private readonly CancellationTokenSource cancellation;
    private readonly TaskCompletionSource force;
    private readonly TimeSpan budget;
    private readonly Stopwatch elapsed = Stopwatch.StartNew();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly TextBlock summary = new() { Margin = new(12), TextWrapping = TextWrapping.Wrap };
    private readonly ListBox programs = new() { Margin = new(12) };
    private bool finished;
    public ExitProgressWindow(Supervisor supervisor, TimeSpan budget, CancellationTokenSource cancellation, TaskCompletionSource force)
    {
        this.supervisor = supervisor; this.budget = budget; this.cancellation = cancellation; this.force = force;
        Title = Text.Get("Exit"); Width = 540; Height = 360; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel(); Content = root; DockPanel.SetDock(summary, Dock.Top); root.Children.Add(summary);
        var controls = new WrapPanel { Margin = new(12) }; DockPanel.SetDock(controls, Dock.Bottom); root.Children.Add(controls);
        var cancel = new Button { Content = Text.Get("CancelExit"), Padding = new(12, 6, 12, 6), Margin = new(4) };
        cancel.Click += (_, _) => { cancel.IsEnabled = false; cancellation.Cancel(); };
        var immediately = new Button { Content = Text.Get("ForceExit"), Padding = new(12, 6, 12, 6), Margin = new(4) };
        immediately.Click += (_, _) => { if (MessageBox.Show(this, Text.Get("ForceConfirm"), "Barback", MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) == MessageBoxResult.OK) { force.TrySetResult(); immediately.IsEnabled = false; } };
        controls.Children.Add(cancel); controls.Children.Add(immediately); root.Children.Add(programs);
        timer.Tick += (_, _) => Refresh(); Loaded += (_, _) => { Refresh(); timer.Start(); };
        Closing += (_, e) => { if (!finished) { e.Cancel = true; cancellation.Cancel(); } };
        Closed += (_, _) => timer.Stop();
    }
    private void Refresh()
    {
        var active = supervisor.Snapshot.Where(s => s.Runtime.Active).ToArray();
        summary.Text = string.Format(Text.Get(force.Task.IsCompleted ? "ExitForceProgress" : "ExitProgress"), active.Length, Math.Max(0, Math.Ceiling((budget - elapsed.Elapsed).TotalSeconds)));
        var selected = programs.SelectedIndex;
        programs.ItemsSource = active.Select(s => s.Config.Name + " — " + Text.Status(s.Runtime.Phase)).ToArray();
        if (selected >= 0 && selected < active.Length) programs.SelectedIndex = selected;
    }
    public void Finish() { if (finished) return; finished = true; Close(); }
}
