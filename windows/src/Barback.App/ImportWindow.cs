using Barback.Core;
namespace Barback.App;

public sealed class ImportWindow : Window
{
    private sealed class Row(ImportDraft draft)
    {
        public ImportDraft Draft { get; } = draft;
        public bool Include { get; set; } = true;
        public string Name { get; set; } = draft.Config.Name;
        public string OriginalCommand => Draft.OriginalCommand;
        public string Issues => string.Join("; ", Draft.Issues.Select(i => $"{i.Field}: {i.Reason}"));
    }
    private readonly TextBox input = new() { AcceptsReturn = true, AcceptsTab = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.Wrap, Margin = new(12) };
    private readonly DataGrid preview = new() { AutoGenerateColumns = false, Margin = new(12), CanUserAddRows = false };
    private Row[] rows = [];
    public ImportWindow(Supervisor supervisor)
    {
        Title = Text.Get("Import"); Width = 900; Height = 700; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        preview.Columns.Add(new DataGridCheckBoxColumn { Header = "Import", Binding = new System.Windows.Data.Binding(nameof(Row.Include)) });
        preview.Columns.Add(new DataGridTextColumn { Header = Text.Get("Name"), Binding = new System.Windows.Data.Binding(nameof(Row.Name)), Width = 150 });
        preview.Columns.Add(new DataGridTextColumn { Header = Text.Get("ScriptText"), Binding = new System.Windows.Data.Binding(nameof(Row.OriginalCommand)), Width = 200, IsReadOnly = true });
        preview.Columns.Add(new DataGridTextColumn { Header = Text.Get("Detail"), Binding = new System.Windows.Data.Binding(nameof(Row.Issues)), Width = new DataGridLength(1, DataGridLengthUnitType.Star), IsReadOnly = true });
        var root = new DockPanel(); Content = root; var controls = new WrapPanel(); DockPanel.SetDock(controls, Dock.Bottom); root.Children.Add(controls);
        controls.Children.Add(MainWindow.Button("Import", () => { rows = SupervisorImporter.Preview(input.Text).Select(d => new Row(d)).ToArray(); preview.ItemsSource = rows; return Task.CompletedTask; }));
        controls.Children.Add(MainWindow.Button("ImportSelected", async () =>
        {
            preview.CommitEdit(DataGridEditingUnit.Cell, true); preview.CommitEdit(DataGridEditingUnit.Row, true);
            var selected = rows.Where(r => r.Include).Select(r => r.Draft.Config with { Name = r.Name }).ToArray(); if (selected.Length == 0) return;
            await supervisor.ImportAsync(selected); Close();
        }));
        var hint = new TextBlock { Text = Text.Get("ImportHint") + "\nRename duplicates in the preview, or uncheck them to skip.", TextWrapping = TextWrapping.Wrap, Margin = new(12) }; DockPanel.SetDock(hint, Dock.Top); root.Children.Add(hint);
        var layout = new Grid(); layout.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); layout.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); layout.Children.Add(input); Grid.SetRow(preview, 1); layout.Children.Add(preview); root.Children.Add(layout);
        input.TextChanged += (_, _) => { rows = []; preview.ItemsSource = null; };
    }
}
