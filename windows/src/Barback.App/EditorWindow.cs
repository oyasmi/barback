using System.ComponentModel;
using System.Text.Json;
using System.Windows.Input;
using Barback.Core;
using Microsoft.Win32;
namespace Barback.App;

public sealed class EditorWindow : Window
{
    private readonly Supervisor supervisor;
    private ProgramConfig saved;
    private readonly Dictionary<string, TextBox> fields = [];
    private readonly Dictionary<string, ComboBox> options = [];
    private readonly StackPanel body = new() { Margin = new(24), MaxWidth = 880, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel secrets = new();
    private readonly List<(TextBox Key, PasswordBox Value, CheckBox Remove)> secretRows = [];
    private readonly CheckBox enabled = new(), autostart = new(), rawMode = new();
    private readonly TextBlock feedback = new() { TextWrapping = TextWrapping.Wrap, Margin = new(12) };
    private string baseline = "";
    private bool allowClose, busy;
    public EditorWindow(Supervisor supervisor, ProgramConfig config)
    {
        this.supervisor = supervisor; saved = config; Title = Text.Get("Edit") + " — " + config.Name; Width = 920; Height = 740; MinWidth = 640; MinHeight = 480; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel(); Content = root;
        var footer = new WrapPanel { Margin = new(12) }; DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        footer.Children.Add(MainWindow.Button("Discard", () => { allowClose = true; Close(); return Task.CompletedTask; }));
        footer.Children.Add(MainWindow.Button("Save", () => SaveAsync(null)));
        if (config.Kind == ProgramKind.Service) footer.Children.Add(MainWindow.Button("SaveRestart", () => SaveAsync(Signal.Restart)));
        footer.Children.Add(MainWindow.Button("SaveStop", () => SaveAsync(Signal.Stop)));
        DockPanel.SetDock(feedback, Dock.Bottom); root.Children.Add(feedback);
        root.Children.Add(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Add("Priority", config.Priority.ToString()); Add("Name", config.Name); Add("Group", config.Group); Add("Notes", config.Notes, true);
        Choose("Mode", config.Launch.Mode); Add("Executable", config.Launch.Executable); body.Children.Add(MainWindow.Button("Browse", () => { var d = new OpenFileDialog { Filter = "Executable|*.exe" }; if (d.ShowDialog(this) == true) fields["Executable"].Text = d.FileName; return Task.CompletedTask; }));
        Add("Arguments", string.Join("\n", config.Launch.Arguments), true); rawMode.Content = Text.Get("Raw"); rawMode.IsChecked = config.Launch.RawArguments is not null; body.Children.Add(rawMode); Add("Raw", config.Launch.RawArguments ?? "", true);
        Add("ScriptPath", config.Launch.ScriptPath); Add("ScriptText", config.Launch.ScriptText, true); Add("WorkingDirectory", config.Launch.WorkingDirectory);
        body.Children.Add(MainWindow.Button("Browse", () => { var d = new OpenFolderDialog(); if (d.ShowDialog(this) == true) fields["WorkingDirectory"].Text = d.FolderName; return Task.CompletedTask; }));
        enabled.Content = Text.Get("Enabled"); enabled.IsChecked = config.Enabled; body.Children.Add(enabled); autostart.Content = Text.Get("Autostart"); autostart.IsChecked = config.Policy.Autostart; autostart.IsEnabled = config.Kind == ProgramKind.Service; body.Children.Add(autostart);
        Choose("Policy", config.Policy.Restart); Choose("StopMode", config.Launch.StopMode);
        Add("StopWait", config.Launch.StopWaitSeconds.ToString()); Add("StartSeconds", config.Policy.StartSeconds.ToString()); Add("Retries", config.Policy.StartRetries.ToString()); Add("Timeout", config.Policy.TimeoutSeconds.ToString()); Add("ExpectedCodes", string.Join(',', config.Policy.ExpectedCodes));
        Add("BackoffBase", config.Policy.BackoffBaseSeconds.ToString()); Add("BackoffMax", config.Policy.BackoffMaxSeconds.ToString()); Add("StormLimit", config.Policy.StormLimit.ToString()); Add("StormWindow", config.Policy.StormWindowSeconds.ToString()); Add("HistoryLimit", config.Policy.HistoryLimit.ToString());
        Add("Encoding", config.Launch.EncodingCodePage.ToString()); Add("LogBytes", config.Launch.LogSegmentBytes.ToString()); Add("LogSegments", config.Launch.LogSegments.ToString());
        Add("Environment", string.Join("\n", config.Launch.Environment.Where(e => !e.Sensitive).Select(e => e.Remove ? "-" + e.Key : e.Key + "=" + e.Value)), true);
        body.Children.Add(new TextBlock { Text = Text.Get("Secrets"), Margin = new(0, 12, 0, 6) }); body.Children.Add(secrets);
        foreach (var e in config.Launch.Environment.Where(e => e.Sensitive)) AddSecret(e.Key, e.Value ?? "", e.Remove);
        body.Children.Add(MainWindow.Button("AddSecret", () => { AddSecret("", "", false); return Task.CompletedTask; }));
        if (config.Launch.Environment.Any(e => e.NeedsInput)) feedback.Text = "Sensitive values require re-entry. This configuration is disabled.";
        options["Mode"].SelectionChanged += (_, _) => UpdateMode(); UpdateMode(); baseline = DraftFingerprint();
        Closing += OnClosing;
        PreviewKeyDown += async (_, e) => { if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; await SaveAsync(null); } };
    }
    private void Add(string key, string value, bool multiline = false)
    {
        var label = new Label { Content = Text.Get(key) }; var field = new TextBox { Text = value, AcceptsReturn = multiline, MinHeight = multiline ? 90 : 0, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden };
        label.Target = field; field.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get(key)); body.Children.Add(label); body.Children.Add(field); fields[key] = field;
    }
    private void Choose<T>(string key, T value) where T : struct, Enum
    {
        var combo = new ComboBox { ItemsSource = Enum.GetValues<T>().Select(v => new Choice<T>(v, Text.Option(v))).ToArray(), DisplayMemberPath = "Label", SelectedValuePath = "Value", SelectedValue = value, Margin = new(0, 3, 0, 12) };
        body.Children.Add(new Label { Content = Text.Get(key), Target = combo }); body.Children.Add(combo); options[key] = combo;
    }
    private sealed record Choice<T>(T Value, string Label);
    private void AddSecret(string key, string value, bool remove)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new(0, 3, 0, 8) }; var name = new TextBox { Text = key, Width = 200 }; var password = new PasswordBox { Password = value, Width = 260, Margin = new(8, 0, 8, 0) }; var deleted = new CheckBox { IsChecked = remove, Content = "Remove" };
        name.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, "Variable name"); password.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("Secrets"));
        row.Children.Add(name); row.Children.Add(password); row.Children.Add(deleted); secrets.Children.Add(row); secretRows.Add((name, password, deleted));
    }
    private void UpdateMode()
    {
        var mode = (ExecutionMode)options["Mode"].SelectedValue;
        fields["Executable"].IsEnabled = mode != ExecutionMode.Cmd; fields["ScriptPath"].IsEnabled = mode == ExecutionMode.PowerShellFile; fields["ScriptText"].IsEnabled = mode is ExecutionMode.PowerShellText or ExecutionMode.Cmd;
        fields["Arguments"].IsEnabled = mode is ExecutionMode.Direct or ExecutionMode.PowerShellFile; rawMode.IsEnabled = mode == ExecutionMode.Direct; fields["Raw"].IsEnabled = mode == ExecutionMode.Direct;
    }
    private string DraftFingerprint() => JsonSerializer.Serialize(new { fields = fields.ToDictionary(k => k.Key, k => k.Value.Text), options = options.ToDictionary(k => k.Key, k => k.Value.SelectedValue), enabled = enabled.IsChecked, autostart = autostart.IsChecked, raw = rawMode.IsChecked, secrets = secretRows.Select(r => new { key = r.Key.Text, value = r.Value.Password, remove = r.Remove.IsChecked }) });
    private ProgramConfig Build()
    {
        string Get(string key) => fields[key].Text;
        double Number(string key) { if (double.TryParse(Get(key), out var n)) return n; fields[key].Focus(); throw new ArgumentException(Text.Get(key) + ": invalid number"); }
        int Integer(string key) { var n = Number(key); if (!double.IsFinite(n) || n != Math.Truncate(n)) throw new ArgumentException(Text.Get(key) + ": enter an integer"); return checked((int)n); }
        var env = EnvironmentDraft.Parse(Get("Environment"));
        if (env.Errors.Length > 0) { fields["Environment"].Focus(); throw new ArgumentException(string.Join("\n", env.Errors.Select(e => $"Line {e.Line}: {e.Message}"))); }
        var all = env.Entries.Concat(secretRows.Where(r => r.Key.Text.Length > 0).Select(r => new EnvironmentEntry(r.Key.Text, r.Value.Password, true, r.Remove.IsChecked == true))).ToArray();
        var mode = (ExecutionMode)options["Mode"].SelectedValue;
        return saved with
        {
            Name = Get("Name"),
            Priority = Integer("Priority"),
            Group = Get("Group"),
            Notes = Get("Notes"),
            Enabled = enabled.IsChecked == true,
            Launch = saved.Launch with { Mode = mode, Executable = Get("Executable"), Arguments = mode is ExecutionMode.PowerShellText or ExecutionMode.Cmd || mode == ExecutionMode.Direct && rawMode.IsChecked == true ? [] : Get("Arguments").Length == 0 ? [] : Get("Arguments").Replace("\r\n", "\n").Split('\n'), RawArguments = mode == ExecutionMode.Direct && rawMode.IsChecked == true ? Get("Raw") : null, ScriptPath = Get("ScriptPath"), ScriptText = Get("ScriptText"), WorkingDirectory = Get("WorkingDirectory"), Environment = all, StopMode = (StopMode)options["StopMode"].SelectedValue, StopWaitSeconds = Number("StopWait"), EncodingCodePage = Integer("Encoding"), LogSegmentBytes = checked((long)Number("LogBytes")), LogSegments = Integer("LogSegments") },
            Policy = saved.Policy with { Autostart = saved.Kind == ProgramKind.Service && autostart.IsChecked == true, Restart = (RestartPolicy)options["Policy"].SelectedValue, StartSeconds = Number("StartSeconds"), StartRetries = Integer("Retries"), TimeoutSeconds = Number("Timeout"), BackoffBaseSeconds = Number("BackoffBase"), BackoffMaxSeconds = Number("BackoffMax"), StormLimit = Integer("StormLimit"), StormWindowSeconds = Number("StormWindow"), HistoryLimit = Integer("HistoryLimit"), ExpectedCodes = Get("ExpectedCodes").Split(',').Select(x => uint.Parse(x.Trim())).ToArray() }
        };
    }
    private async Task SaveAsync(Signal? after)
    {
        if (busy) return; busy = true; IsEnabled = false;
        try
        {
            var c = Build();
            if (c.Launch.StopMode == StopMode.TerminateJob && (saved.Version == 0 || saved.Launch.StopMode != StopMode.TerminateJob) && !MainWindow.Confirm("ForceConfirm")) return;
            var errors = ConfigurationValidator.Validate(c, false);
            if (errors.Count > 0) { if (fields.TryGetValue(errors[0].Field, out var field)) field.Focus(); throw new ArgumentException(string.Join("\n", errors.Select(e => $"{e.Field}: {e.Message}"))); }
            await supervisor.SaveAsync(c, saved.Version);
            saved = supervisor.Snapshot.Single(s => s.Config.Id == c.Id).Config; baseline = DraftFingerprint(); feedback.Text = Text.Get("Pending");
            if (after is Signal action) await supervisor.SendAsync(saved.Id, action);
        }
        catch (Exception ex) { feedback.Text = Text.Get("Error") + "\n" + ex.Message; }
        finally { busy = false; IsEnabled = true; }
    }
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (allowClose) return;
        if (busy) { e.Cancel = true; return; }
        if (DraftFingerprint() == baseline) return;
        e.Cancel = true; var answer = MessageBox.Show(Text.Get("DirtyPrompt"), "Barback", MessageBoxButton.YesNoCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer == MessageBoxResult.Cancel) return;
        if (answer == MessageBoxResult.Yes) { await SaveAsync(null); if (DraftFingerprint() != baseline) return; }
        allowClose = true; Close();
    }
}
