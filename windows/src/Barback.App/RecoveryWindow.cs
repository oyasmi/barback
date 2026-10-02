using Barback.Core;
using Barback.Storage;
using Microsoft.Win32;
namespace Barback.App;
/// <summary>Explicit recovery preserves the source database and imports configuration only, disabled.</summary>
public sealed class RecoveryWindow : Window
{
    private readonly string root;
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Margin = new(12) };
    private readonly TextBox source = new() { Margin = new(12), IsReadOnly = true };
    private readonly CheckBox confirm = new() { Margin = new(12), Content = Text.Get("RecoveryConfirm") };
    public bool Restored { get; private set; }
    public RecoveryWindow(string root, Exception error)
    {
        this.root = root; Title = Text.Get("RecoveryTitle"); Width = 760; Height = 420; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var panel = new StackPanel { Margin = new(24) }; Content = new ScrollViewer { Content = panel };
        status.Text = Text.Get("RecoveryStatus") + "\n" + error.Message + "\n" + root; panel.Children.Add(status); panel.Children.Add(source); panel.Children.Add(confirm);
        panel.Children.Add(MainWindow.Button("OpenData", () => { ShellIntegration.Open(root); return Task.CompletedTask; }));
        panel.Children.Add(MainWindow.Button("Browse", () => { var dialog = new OpenFileDialog { Filter = "Barback configuration backup|*.json", InitialDirectory = Path.Combine(root, "backups") }; if (dialog.ShowDialog(this) == true) source.Text = dialog.FileName; return Task.CompletedTask; }));
        panel.Children.Add(MainWindow.Button("Restore", RestoreAsync));
    }
    private async Task RestoreAsync()
    {
        if (!confirm.IsChecked.GetValueOrDefault() || !File.Exists(source.Text)) return;
        var configs = ConfigurationBackupReader.Read(await File.ReadAllTextAsync(source.Text), new DpapiProtector());
        var evidence = Path.Combine(root, "backups", "recovery-source-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss") + "-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(evidence);
        foreach (var name in new[] { "barback.db", "barback.db-wal", "barback.db-shm" }) { var original = Path.Combine(root, name); if (File.Exists(original)) File.Move(original, Path.Combine(evidence, name)); }
        try
        {
            await using var store = await SqliteStore.OpenAsync(root); await store.ImportAsync(configs); await store.MarkCleanAsync(); Restored = true; DialogResult = true;
        }
        catch
        {
            // Preserve both the failed new database and the original before allowing another attempt.
            foreach (var name in new[] { "barback.db", "barback.db-wal", "barback.db-shm" }) { var file = Path.Combine(root, name); if (File.Exists(file)) File.Move(file, Path.Combine(evidence, "failed-new-" + name)); var original = Path.Combine(evidence, name); if (File.Exists(original)) File.Copy(original, file); }
            throw;
        }
    }
}
