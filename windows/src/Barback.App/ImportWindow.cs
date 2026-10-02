using System.ComponentModel;
using System.Runtime.CompilerServices;
using Barback.Core;
namespace Barback.App;

public sealed class ImportWindow : Window
{
    private sealed class Row(ImportDraft draft, Action changed) : INotifyPropertyChanged
    {
        private bool include = true;
        private string name = draft.Config.Name, status = "";
        public ImportDraft Draft { get; } = draft;
        public bool Include { get => include; set { if (include == value) return; include = value; Raise(); changed(); } }
        public string Name { get => name; set { if (name == value) return; name = value; Raise(); changed(); } }
        /// <summary>Name collision (with an existing program or another selected row); empty when the row can be imported.</summary>
        public string Status { get => status; set { if (status == value) return; status = value; Raise(); } }
        public string OriginalCommand => Draft.OriginalCommand;
        public string Issues => string.Join("; ", Draft.Issues.Select(i => $"{i.Field}: {i.Reason}"));
        public event PropertyChangedEventHandler? PropertyChanged;
        private void Raise([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }
    private readonly TextBox input = new() { AcceptsReturn = true, AcceptsTab = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.Wrap, Margin = new(12) };
    private readonly DataGrid preview = new() { AutoGenerateColumns = false, Margin = new(12), CanUserAddRows = false };
    private readonly TextBlock feedback = new() { TextWrapping = TextWrapping.Wrap, Margin = new(12) };
    private readonly Supervisor supervisor;
    private readonly Button importButton;
    private Row[] rows = [];
    public ImportWindow(Supervisor supervisor)
    {
        this.supervisor = supervisor;
        Title = Text.Get("Import"); Width = 900; Height = 700; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        preview.Columns.Add(new DataGridCheckBoxColumn { Header = Text.Get("ImportColumn"), Binding = new System.Windows.Data.Binding(nameof(Row.Include)) });
        preview.Columns.Add(new DataGridTextColumn { Header = Text.Get("Name"), Binding = new System.Windows.Data.Binding(nameof(Row.Name)), Width = 150 });
        preview.Columns.Add(new DataGridTextColumn { Header = Text.Get("Status"), Binding = new System.Windows.Data.Binding(nameof(Row.Status)), Width = 170, IsReadOnly = true });
        preview.Columns.Add(new DataGridTextColumn { Header = Text.Get("ScriptText"), Binding = new System.Windows.Data.Binding(nameof(Row.OriginalCommand)), Width = 200, IsReadOnly = true });
        preview.Columns.Add(new DataGridTextColumn { Header = Text.Get("Detail"), Binding = new System.Windows.Data.Binding(nameof(Row.Issues)), Width = new DataGridLength(1, DataGridLengthUnitType.Star), IsReadOnly = true });
        var root = new DockPanel(); Content = root; var controls = new WrapPanel(); DockPanel.SetDock(controls, Dock.Bottom); root.Children.Add(controls);
        controls.Children.Add(MainWindow.Button("Import", () => { rows = SupervisorImporter.Preview(input.Text).Select(d => new Row(d, Revalidate)).ToArray(); preview.ItemsSource = rows; Revalidate(); return Task.CompletedTask; }));
        importButton = MainWindow.Button("ImportSelected", async () =>
        {
            preview.CommitEdit(DataGridEditingUnit.Cell, true); preview.CommitEdit(DataGridEditingUnit.Row, true);
            Revalidate(); if (!importButton!.IsEnabled) return;
            var selected = rows.Where(r => r.Include).Select(r => r.Draft.Config with { Name = r.Name }).ToArray(); if (selected.Length == 0) return;
            await supervisor.ImportAsync(selected); Close();
        });
        importButton.IsEnabled = false; controls.Children.Add(importButton);
        var hint = new TextBlock { Text = Text.Get("ImportHint") + "\n" + Text.Get("ImportRenameHint"), TextWrapping = TextWrapping.Wrap, Margin = new(12) }; DockPanel.SetDock(hint, Dock.Top); root.Children.Add(hint);
        DockPanel.SetDock(feedback, Dock.Bottom); root.Children.Add(feedback);
        var layout = new Grid(); layout.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); layout.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); layout.Children.Add(input); Grid.SetRow(preview, 1); layout.Children.Add(preview); root.Children.Add(layout);
        input.TextChanged += (_, _) => { rows = []; preview.ItemsSource = null; Revalidate(); };
    }
    /// <summary>Re-evaluates name collisions after any rename or selection change; importing stays disabled while a selected row collides.</summary>
    private void Revalidate()
    {
        var existing = supervisor.Snapshot.Select(s => s.Config.NameKey).ToHashSet();
        var seen = new HashSet<string>(); int conflicts = 0;
        foreach (var row in rows)
        {
            if (!row.Include) { row.Status = ""; continue; }
            var key = ProgramNames.Key(row.Name);
            row.Status = row.Name.Trim().Length == 0 ? Text.Get("ImportNameRequired") : existing.Contains(key) ? Text.Get("ImportConflictExisting") : !seen.Add(key) ? Text.Get("ImportConflictBatch") : "";
            if (row.Status.Length > 0) conflicts++;
        }
        importButton.IsEnabled = rows.Any(r => r.Include) && conflicts == 0;
        feedback.Text = conflicts > 0 ? Text.Format("ImportBlocked", conflicts) : "";
    }
}
