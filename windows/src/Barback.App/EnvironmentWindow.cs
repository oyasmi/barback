using System.ComponentModel;
using System.Text.Json;
using Barback.Core;
using Barback.Storage;
using Barback.Windows;
namespace Barback.App;

public sealed class EnvironmentWindow : Window
{
    private readonly TextBox draft = new() { AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new(12) };
    private readonly StackPanel secretPanel = new() { Margin = new(12) };
    private readonly List<(WrapPanel Row, TextBox Key, PasswordBox Value, CheckBox Remove)> secretRows = [];
    private readonly HashSet<PasswordBox> unresolvedSecrets = [];
    private readonly TextBlock error = new() { Margin = new(12), TextWrapping = TextWrapping.Wrap };
    private readonly SqliteStore store;
    private readonly WindowsProcessHost host;
    private string baseline = "";
    private bool loaded, busy, allowClose;
    public EnvironmentWindow(SqliteStore store, WindowsProcessHost host)
    {
        this.store = store; this.host = host; Title = Text.Get("Environment"); Width = 720; Height = 620; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel(); Content = root; var controls = new WrapPanel(); DockPanel.SetDock(controls, Dock.Bottom); root.Children.Add(controls);
        controls.Children.Add(MainWindow.Button("Save", SaveAsync)); controls.Children.Add(MainWindow.Button("AddSecret", () => { Secret(new("", "", true)); return Task.CompletedTask; }));
        DockPanel.SetDock(error, Dock.Bottom); root.Children.Add(error); DockPanel.SetDock(secretPanel, Dock.Bottom); root.Children.Add(secretPanel); root.Children.Add(draft);
        draft.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("Environment"));
        Loaded += async (_, _) => await MainWindow.RunGuardedAsync(async () =>
        {
            // Undecryptable values come back as NeedsInput placeholders, so the window always opens and can repair them.
            var entries = await ApplicationEnvironment.LoadAsync(store, new DpapiProtector());
            draft.Text = string.Join("\n", entries.Where(e => !e.Sensitive).Select(e => e.Remove ? "-" + e.Key : e.Key + "=" + e.Value));
            foreach (var e in entries.Where(e => e.Sensitive)) Secret(e);
            if (entries.Any(e => e.NeedsInput)) error.Text = Text.Get("ApplicationEnvironmentNeedsInput");
            loaded = true; baseline = Fingerprint();
        });
        Closing += OnClosing;
    }
    private void Secret(EnvironmentEntry entry)
    {
        var row = new WrapPanel();
        var key = new TextBox { Text = entry.Key, Width = 180 };
        var password = new PasswordBox { Password = entry.Value ?? "", Width = 240, Margin = new(8) };
        var remove = new CheckBox { Content = Text.Get("RemoveVariable"), IsChecked = entry.Remove, VerticalAlignment = VerticalAlignment.Center };
        var hint = new TextBlock { Text = Text.Get("NeedsReentry"), VerticalAlignment = VerticalAlignment.Center, Margin = new(8, 0, 8, 0), Foreground = (System.Windows.Media.Brush)Application.Current.FindResource("DangerBrush") };
        var delete = new Button { Content = Text.Get("RemoveRow"), Margin = new(8, 0, 0, 0), Padding = new(8, 2, 8, 2) };
        key.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("VariableName"));
        password.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("Secrets"));
        row.Children.Add(key); row.Children.Add(password); row.Children.Add(remove); row.Children.Add(hint); row.Children.Add(delete);
        secretPanel.Children.Add(row); secretRows.Add((row, key, password, remove));
        if (entry.NeedsInput) unresolvedSecrets.Add(password); else hint.Visibility = Visibility.Collapsed;
        password.PasswordChanged += (_, _) => { unresolvedSecrets.Remove(password); hint.Visibility = Visibility.Collapsed; };
        delete.Click += (_, _) =>
        {
            secretPanel.Children.Remove(row); unresolvedSecrets.Remove(password);
            secretRows.RemoveAll(r => r.Row == row);
        };
    }
    private string Fingerprint() => JsonSerializer.Serialize(new { raw = draft.Text, secrets = secretRows.Select(r => new { key = r.Key.Text, value = r.Value.Password, remove = r.Remove.IsChecked, needsInput = unresolvedSecrets.Contains(r.Value) }) });
    private async Task SaveAsync()
    {
        if (busy || !loaded) return; busy = true;
        try
        {
            var parsed = EnvironmentDraft.Parse(draft.Text); if (parsed.Errors.Length > 0) throw new ArgumentException(string.Join("\n", parsed.Errors.Select(e => Text.Format("EnvironmentError", e.Line ?? 0, e.Message))));
            var secrets = secretRows.Where(r => r.Key.Text.Length > 0)
                .Select(r => new EnvironmentEntry(r.Key.Text, r.Value.Password, true, r.Remove.IsChecked == true, unresolvedSecrets.Contains(r.Value) && r.Remove.IsChecked != true));
            var entries = parsed.Entries.Concat(secrets).ToArray();
            var check = ConfigurationValidator.Validate(new() { Name = "application environment", Enabled = false, Launch = new() { Environment = entries } }, false); if (check.Count > 0) throw new ArgumentException(string.Join("\n", check.Select(e => e.Message)));
            await ApplicationEnvironment.SaveAsync(store, new DpapiProtector(), entries);
            host.SetApplicationEnvironment(entries.Select(e => e.NeedsInput ? e with { Value = null } : e).ToArray());
            baseline = Fingerprint(); error.Text = entries.Any(e => e.NeedsInput) ? Text.Get("ApplicationEnvironmentNeedsInput") : Text.Get("Pending");
        }
        catch (Exception ex) { error.Text = ex.Message; }
        finally { busy = false; }
    }
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (allowClose || !loaded || Fingerprint() == baseline) return; e.Cancel = true; if (busy) return;
        var answer = MessageBox.Show(Text.Get("DirtyPrompt"), "Barback", MessageBoxButton.YesNoCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer == MessageBoxResult.Cancel) return; if (answer == MessageBoxResult.Yes) { await SaveAsync(); if (Fingerprint() != baseline) return; }
        allowClose = true; Close();
    }
}
