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
    private readonly List<(TextBox Key, PasswordBox Value, CheckBox Remove)> secretRows = [];
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
            var value = await store.GetSettingAsync("application_environment"); var entries = value is null ? [] : JsonSerializer.Deserialize<EnvironmentEntry[]>(value)!; var protector = new DpapiProtector();
            draft.Text = string.Join("\n", entries.Where(e => !e.Sensitive).Select(e => e.Remove ? "-" + e.Key : e.Key + "=" + e.Value));
            foreach (var e in entries.Where(e => e.Sensitive)) Secret(e with { Value = e.Remove || e.NeedsInput ? null : protector.Unprotect(e.Value ?? "") }); loaded = true; baseline = Fingerprint();
        });
        Closing += OnClosing;
    }
    private void Secret(EnvironmentEntry entry)
    {
        var row = new WrapPanel(); var key = new TextBox { Text = entry.Key, Width = 180 }; var password = new PasswordBox { Password = entry.Value ?? "", Width = 240, Margin = new(8) }; var remove = new CheckBox { Content = "Remove", IsChecked = entry.Remove }; row.Children.Add(key); row.Children.Add(password); row.Children.Add(remove); secretPanel.Children.Add(row); secretRows.Add((key, password, remove));
    }
    private string Fingerprint() => JsonSerializer.Serialize(new { raw = draft.Text, secrets = secretRows.Select(r => new { key = r.Key.Text, value = r.Value.Password, remove = r.Remove.IsChecked }) });
    private async Task SaveAsync()
    {
        if (busy || !loaded) return; busy = true;
        try
        {
            var parsed = EnvironmentDraft.Parse(draft.Text); if (parsed.Errors.Length > 0) throw new ArgumentException(string.Join("\n", parsed.Errors.Select(e => $"Line {e.Line}: {e.Message}")));
            var entries = parsed.Entries.Concat(secretRows.Where(r => r.Key.Text.Length > 0).Select(r => new EnvironmentEntry(r.Key.Text, r.Value.Password, true, r.Remove.IsChecked == true))).ToArray();
            var check = ConfigurationValidator.Validate(new() { Name = "application environment", Enabled = false, Launch = new() { Environment = entries } }, false); if (check.Count > 0) throw new ArgumentException(string.Join("\n", check.Select(e => e.Message)));
            var protector = new DpapiProtector(); var encoded = entries.Select(e => e.Sensitive && !e.Remove ? e with { Value = protector.Protect(e.Value ?? "") } : e).ToArray();
            await store.SetSettingAsync("application_environment", JsonSerializer.Serialize(encoded)); host.SetApplicationEnvironment(entries); baseline = Fingerprint(); error.Text = Text.Get("Pending");
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
