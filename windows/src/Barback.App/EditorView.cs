using System.Text.Json;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using Barback.Core;
using Microsoft.Win32;

namespace Barback.App;

public sealed class EditorView : UserControl, IDisposable
{
    private readonly Supervisor supervisor;
    private ProgramConfig saved;
    private readonly Dictionary<string, TextBox> fields = [];
    private readonly Dictionary<string, ComboBox> options = [];
    private readonly Dictionary<string, FrameworkElement> wrappers = [];
    private readonly StackPanel body = new() { Margin = new(24, 0, 24, 24), MaxWidth = 800 };
    private Panel section;
    private readonly StackPanel secrets = new();
    private readonly List<(TextBox Key, PasswordBox Value, CheckBox Remove)> secretRows = [];
    private readonly HashSet<PasswordBox> unresolvedSecrets = [];
    private readonly CheckBox enabled = new(), autostart = new(), rawMode = new();
    private readonly TextBlock feedback = new() { TextWrapping = TextWrapping.Wrap, Margin = new(24, 0, 24, 10) };
    private readonly Button saveButton, restartButton, stopButton;
    private string baseline = "";
    private bool busy, initialized, disposed;
    public event EventHandler? CancelRequested;

    public EditorView(Supervisor supervisor, ProgramConfig config)
    {
        this.supervisor = supervisor; saved = config; section = body;
        SetResourceReference(ForegroundProperty, "PrimaryTextBrush"); SetResourceReference(BackgroundProperty, "SurfaceBrush");
        var root = new Grid(); root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new()); root.RowDefinitions.Add(new() { Height = GridLength.Auto }); Content = root;
        root.Children.Add(feedback);
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; Grid.SetRow(scroll, 1); root.Children.Add(scroll);
        var footer = new Border { Padding = new(24, 16, 24, 16), BorderThickness = new(0, 1, 0, 0) }; footer.SetResourceReference(Border.BorderBrushProperty, "LineBrush"); Grid.SetRow(footer, 2); root.Children.Add(footer);
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right }; footer.Child = actions;
        var cancel = MakeButton("Cancel", () => { CancelRequested?.Invoke(this, EventArgs.Empty); return Task.CompletedTask; });
        saveButton = MakeButton("Save", async () => await SaveAsync(null));
        restartButton = MakeButton("SaveRestart", async () => await SaveAsync(Signal.Restart));
        stopButton = MakeButton("SaveStop", async () => await SaveAsync(Signal.Stop));
        saveButton.Style = (Style)FindResource("AccentButton"); actions.Children.Add(cancel); actions.Children.Add(saveButton); actions.Children.Add(restartButton); actions.Children.Add(stopButton);
        var basic = new Grid(); basic.ColumnDefinitions.Add(new()); basic.ColumnDefinitions.Add(new()); body.Children.Add(basic);
        var left = new StackPanel { Margin = new(0, 0, 8, 0) }; var right = new StackPanel { Margin = new(8, 0, 0, 0) }; Grid.SetColumn(right, 1); basic.Children.Add(left); basic.Children.Add(right);
        section = left; Add("Name", config.Name); section = right; Add("Group", config.Group); section = body;
        Choose("Mode", config.Launch.Mode); Add("Executable", config.Launch.Executable);
        var browseExe = MakeButton("Browse", () => { var dialog = new OpenFileDialog { Filter = "Executable|*.exe" }; if (dialog.ShowDialog(Window.GetWindow(this)) == true) fields["Executable"].Text = dialog.FileName; return Task.CompletedTask; });
        browseExe.HorizontalAlignment = HorizontalAlignment.Left; body.Children.Add(browseExe); wrappers["BrowseExecutable"] = browseExe;
        Add("Arguments", string.Join("\n", config.Launch.Arguments), true); Add("ScriptPath", config.Launch.ScriptPath); Add("ScriptText", config.Launch.ScriptText, true); Add("WorkingDirectory", config.Launch.WorkingDirectory);
        var browseDir = MakeButton("BrowseDirectory", () => { var dialog = new OpenFolderDialog(); if (dialog.ShowDialog(Window.GetWindow(this)) == true) fields["WorkingDirectory"].Text = dialog.FolderName; return Task.CompletedTask; }); browseDir.HorizontalAlignment = HorizontalAlignment.Left; body.Children.Add(browseDir);
        enabled.Content = Text.Get("Enabled"); enabled.IsChecked = config.Enabled; enabled.Margin = new(0, 14, 0, 8); body.Children.Add(enabled);
        autostart.Content = Text.Get("Autostart"); autostart.IsChecked = config.Policy.Autostart; autostart.Margin = new(0, 0, 0, 12); autostart.Visibility = config.Kind == ProgramKind.Service ? Visibility.Visible : Visibility.Collapsed; body.Children.Add(autostart);
        if (config.Kind == ProgramKind.Service) Choose("Policy", config.Policy.Restart);
        section = NewSection("Environment", Text.Get("InheritedEnvironment"));
        Add("Environment", string.Join("\n", config.Launch.Environment.Where(e => !e.Sensitive).Select(e => e.Remove ? "-" + e.Key : e.Key + "=" + e.Value)), true);
        section.Children.Add(new TextBlock { Text = Text.Get("EnvironmentSyntax"), Style = (Style)FindResource("Caption"), Margin = new(0, 0, 0, 12) });
        section.Children.Add(new TextBlock { Text = Text.Get("Secrets"), Margin = new(0, 0, 0, 8) }); section.Children.Add(secrets);
        foreach (var entry in config.Launch.Environment.Where(e => e.Sensitive)) AddSecret(entry.Key, entry.Value ?? "", entry.Remove, entry.NeedsInput);
        section.Children.Add(MakeButton("AddSecret", () => { AddSecret("", "", false); UpdateDirty(); return Task.CompletedTask; }));
        section = NewSection("AdvancedLaunch", Text.Option(config.Launch.Mode)); Add("Priority", config.Priority.ToString()); rawMode.Content = Text.Get("Raw"); rawMode.IsChecked = config.Launch.RawArguments is not null; section.Children.Add(rawMode); Add("Raw", config.Launch.RawArguments ?? "", true);
        section = NewSection("RetrySettings", config.Kind == ProgramKind.Service ? Text.Format("RetrySummary", config.Policy.StartSeconds, config.Policy.StartRetries) : Text.Format("TimeoutSummary", config.Policy.TimeoutSeconds));
        if (config.Kind == ProgramKind.Service) { Add("StartSeconds", config.Policy.StartSeconds.ToString()); Add("Retries", config.Policy.StartRetries.ToString()); Add("BackoffBase", config.Policy.BackoffBaseSeconds.ToString()); Add("BackoffMax", config.Policy.BackoffMaxSeconds.ToString()); Add("StormLimit", config.Policy.StormLimit.ToString()); Add("StormWindow", config.Policy.StormWindowSeconds.ToString()); }
        else Add("Timeout", config.Policy.TimeoutSeconds.ToString());
        Add("ExpectedCodes", string.Join(',', config.Policy.ExpectedCodes)); Add("HistoryLimit", config.Policy.HistoryLimit.ToString());
        section = NewSection("StopSettings", Text.Option(config.Launch.StopMode)); Choose("StopMode", config.Launch.StopMode); Add("StopWait", config.Launch.StopWaitSeconds.ToString());
        section = NewSection("LogSettings", Text.Format("LogSummary", config.Launch.EncodingCodePage, config.Launch.LogSegmentBytes / 1048576d, config.Launch.LogSegments)); Add("Encoding", config.Launch.EncodingCodePage.ToString()); Add("LogBytes", (config.Launch.LogSegmentBytes / 1048576d).ToString()); Add("LogSegments", config.Launch.LogSegments.ToString());
        section = NewSection("Notes", config.Notes.Length == 0 ? Text.Get("Optional") : config.Notes); Add("Notes", config.Notes, true);
        if (config.Launch.Environment.Any(e => e.NeedsInput)) feedback.Text = Text.Get("SecretsNeedInput");
        options["Mode"].SelectionChanged += (_, _) => UpdateMode(); rawMode.Click += (_, _) => UpdateMode();
        body.AddHandler(TextBoxBase.TextChangedEvent, new TextChangedEventHandler((_, _) => UpdateDirty()));
        body.AddHandler(PasswordBox.PasswordChangedEvent, new RoutedEventHandler((_, _) => UpdateDirty()));
        body.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler((_, _) => UpdateDirty()));
        foreach (var combo in options.Values) combo.SelectionChanged += (_, _) => UpdateDirty();
        UpdateMode(); baseline = DraftFingerprint(); initialized = true; UpdateDirty();
        supervisor.Changed += SupervisorChanged;
        PreviewKeyDown += async (_, e) => { if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; await SaveAsync(null); } };
        Loaded += (_, _) => { fields["Name"].Focus(); };
    }

    private Button MakeButton(string key, Func<Task> action)
    {
        var button = new Button { Content = Text.Get(key), Style = (Style)FindResource("WorkbenchButton"), Margin = new(0, 4, 8, 4) };
        button.Click += async (_, _) => await MainWindow.RunGuardedAsync(action); return button;
    }
    private Panel NewSection(string key, string summary)
    {
        var content = new StackPanel { Margin = new(0, 12, 0, 8) };
        var header = new StackPanel { Orientation = Orientation.Horizontal }; header.Children.Add(new TextBlock { Text = Text.Get(key) }); header.Children.Add(new TextBlock { Text = "   " + summary, Style = (Style)FindResource("Caption"), MaxWidth = 380, TextTrimming = TextTrimming.CharacterEllipsis });
        body.Children.Add(new Expander { Header = header, Content = content, Margin = new(0, 8, 0, 0), HorizontalContentAlignment = HorizontalAlignment.Stretch }); return content;
    }
    private void Add(string key, string value, bool multiline = false)
    {
        var field = new TextBox { Text = value, AcceptsReturn = multiline, MinHeight = multiline ? 80 : 0, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden, Style = (Style)FindResource("WorkbenchInput") };
        var wrapper = new StackPanel { Margin = new(0, 0, 0, 14) }; wrapper.Children.Add(new Label { Content = Text.Get(key), Target = field, Padding = new(0, 0, 0, 6) }); wrapper.Children.Add(field);
        field.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get(key)); section.Children.Add(wrapper); fields[key] = field; wrappers[key] = wrapper;
    }
    private void Choose<T>(string key, T value) where T : struct, Enum
    {
        var combo = new ComboBox { ItemsSource = Enum.GetValues<T>().Select(v => new Choice<T>(v, Text.Option(v))).ToArray(), DisplayMemberPath = "Label", SelectedValuePath = "Value", SelectedValue = value, Margin = new(0, 0, 0, 14) };
        section.Children.Add(new Label { Content = Text.Get(key), Target = combo, Padding = new(0, 0, 0, 6) }); section.Children.Add(combo); options[key] = combo;
    }
    private sealed record Choice<T>(T Value, string Label);
    private void AddSecret(string key, string value, bool remove, bool needsInput = false)
    {
        var row = new Grid { Margin = new(0, 0, 0, 10) }; row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = new GridLength(2, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var name = new TextBox { Text = key, Style = (Style)FindResource("WorkbenchInput"), Margin = new(0, 0, 8, 0) };
        var password = new PasswordBox { Password = value, Padding = new(8), Margin = new(0, 0, 8, 0) }; var removed = new CheckBox { IsChecked = remove, Content = Text.Get("RemoveVariable"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(password, 1); Grid.SetColumn(removed, 2); row.Children.Add(name); row.Children.Add(password); row.Children.Add(removed); secrets.Children.Add(row); secretRows.Add((name, password, removed));
        if (needsInput) unresolvedSecrets.Add(password);
        password.PasswordChanged += (_, _) => unresolvedSecrets.Remove(password);
        name.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("VariableName")); password.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("Secrets"));
    }
    private void UpdateMode()
    {
        var mode = (ExecutionMode)options["Mode"].SelectedValue;
        void Show(string key, bool visible) => wrappers[key].Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        Show("Executable", mode != ExecutionMode.Cmd); Show("BrowseExecutable", mode != ExecutionMode.Cmd);
        Show("ScriptPath", mode == ExecutionMode.PowerShellFile); Show("ScriptText", mode is ExecutionMode.PowerShellText or ExecutionMode.Cmd);
        Show("Arguments", mode == ExecutionMode.PowerShellFile || mode == ExecutionMode.Direct && rawMode.IsChecked != true);
        rawMode.Visibility = mode == ExecutionMode.Direct ? Visibility.Visible : Visibility.Collapsed; Show("Raw", mode == ExecutionMode.Direct && rawMode.IsChecked == true);
    }
    private string DraftFingerprint() => JsonSerializer.Serialize(new { fields = fields.ToDictionary(k => k.Key, k => k.Value.Text), options = options.ToDictionary(k => k.Key, k => k.Value.SelectedValue), enabled = enabled.IsChecked, autostart = autostart.IsChecked, raw = rawMode.IsChecked, secrets = secretRows.Select(r => new { key = r.Key.Text, value = r.Value.Password, remove = r.Remove.IsChecked, needsInput = unresolvedSecrets.Contains(r.Value) && r.Remove.IsChecked != true }) });
    private void SupervisorChanged() => Dispatcher.BeginInvoke(() => { if (!disposed) UpdateDirty(); });
    private void UpdateDirty()
    {
        if (!initialized || disposed) return;
        bool dirty = DraftFingerprint() != baseline;
        saveButton.IsEnabled = dirty && !busy;
        var snapshot = supervisor.Snapshot.FirstOrDefault(s => s.Config.Id == saved.Id);
        bool active = snapshot?.Runtime.Active == true;
        restartButton.Visibility = saved.Kind == ProgramKind.Service && active ? Visibility.Visible : Visibility.Collapsed;
        restartButton.IsEnabled = dirty && !busy && enabled.IsChecked == true && snapshot is not null && ProgramActionPolicy.CanRestart(snapshot);
        stopButton.Visibility = active && enabled.IsChecked != true ? Visibility.Visible : Visibility.Collapsed; stopButton.IsEnabled = dirty && !busy;
    }
    private ProgramConfig Build()
    {
        string Get(string key) => fields[key].Text;
        double Number(string key) { if (double.TryParse(Get(key), out var number) && double.IsFinite(number)) return number; FocusField(key); throw new ArgumentException(Text.Format("InvalidNumber", Text.Get(key))); }
        int Integer(string key) { var number = Number(key); if (number != Math.Truncate(number)) { FocusField(key); throw new ArgumentException(Text.Format("InvalidInteger", Text.Get(key))); } return checked((int)number); }
        var environment = EnvironmentDraft.Parse(Get("Environment"));
        if (environment.Errors.Length > 0) { FocusField("Environment"); throw new ArgumentException(string.Join("\n", environment.Errors.Select(e => Text.Format("EnvironmentError", e.Line ?? 0, e.Message)))); }
        var all = environment.Entries.Concat(secretRows.Where(r => r.Key.Text.Length > 0).Select(r => new EnvironmentEntry(r.Key.Text, r.Value.Password, true, r.Remove.IsChecked == true, unresolvedSecrets.Contains(r.Value) && r.Remove.IsChecked != true))).ToArray();
        var mode = (ExecutionMode)options["Mode"].SelectedValue;
        var codes = new List<uint>();
        foreach (var code in Get("ExpectedCodes").Split(','))
        {
            if (!uint.TryParse(code.Trim(), out var value)) { FocusField("ExpectedCodes"); throw new ArgumentException(Text.Format("InvalidInteger", Text.Get("ExpectedCodes"))); }
            codes.Add(value);
        }
        var policy = saved.Policy with { Autostart = saved.Kind == ProgramKind.Service && autostart.IsChecked == true, HistoryLimit = Integer("HistoryLimit"), ExpectedCodes = codes.ToArray() };
        if (saved.Kind == ProgramKind.Service) policy = policy with { Restart = (RestartPolicy)options["Policy"].SelectedValue, StartSeconds = Number("StartSeconds"), StartRetries = Integer("Retries"), BackoffBaseSeconds = Number("BackoffBase"), BackoffMaxSeconds = Number("BackoffMax"), StormLimit = Integer("StormLimit"), StormWindowSeconds = Number("StormWindow") };
        else policy = policy with { TimeoutSeconds = Number("Timeout") };
        return saved with
        {
            Name = Get("Name"), Priority = Integer("Priority"), Group = Get("Group"), Notes = Get("Notes"), Enabled = enabled.IsChecked == true,
            Launch = saved.Launch with { Mode = mode, Executable = Get("Executable"), Arguments = mode is ExecutionMode.PowerShellText or ExecutionMode.Cmd || mode == ExecutionMode.Direct && rawMode.IsChecked == true ? [] : Get("Arguments").Length == 0 ? [] : Get("Arguments").Replace("\r\n", "\n").Split('\n'), RawArguments = mode == ExecutionMode.Direct && rawMode.IsChecked == true ? Get("Raw") : null, ScriptPath = Get("ScriptPath"), ScriptText = Get("ScriptText"), WorkingDirectory = Get("WorkingDirectory"), Environment = all, StopMode = (StopMode)options["StopMode"].SelectedValue, StopWaitSeconds = Number("StopWait"), EncodingCodePage = Integer("Encoding"), LogSegmentBytes = checked((long)Math.Round(Number("LogBytes") * 1048576)), LogSegments = Integer("LogSegments") },
            Policy = policy
        };
    }
    private void FocusField(string key)
    {
        key = key switch { "StopWaitSeconds" => "StopWait", "StartRetries" => "Retries", "Backoff" => "BackoffBase", "Storm" => "StormLimit", "History" => "ExpectedCodes", "Logs" => "LogBytes", _ => key };
        if (!fields.TryGetValue(key, out var field)) return;
        for (DependencyObject? parent = field; parent is not null; parent = LogicalTreeHelper.GetParent(parent)) if (parent is Expander expander) expander.IsExpanded = true;
        Dispatcher.BeginInvoke(() => { field.BringIntoView(); field.Focus(); }, System.Windows.Threading.DispatcherPriority.Input);
    }
    private async Task<bool> SaveAsync(Signal? after)
    {
        if (busy) return false; busy = true; body.IsEnabled = false; UpdateDirty();
        try
        {
            var config = Build();
            if (config.Launch.StopMode == StopMode.TerminateJob && (saved.Version == 0 || saved.Launch.StopMode != StopMode.TerminateJob) && !MainWindow.Confirm("ForceConfirm")) return false;
            var errors = ConfigurationValidator.Validate(config, false);
            if (errors.Count > 0) { FocusField(errors[0].Field); throw new ArgumentException(string.Join("\n", errors.Select(e => Text.Get(e.Field) + ": " + e.Message))); }
            await supervisor.SaveAsync(config, saved.Version);
            saved = supervisor.Snapshot.Single(s => s.Config.Id == config.Id).Config; baseline = DraftFingerprint(); feedback.Text = Text.Get("SavedConfiguration") + (saved.Launch.Environment.Any(e => e.NeedsInput) ? "\n" + Text.Get("SecretsNeedInput") : "");
            if (after is Signal signal) await supervisor.SendAsync(saved.Id, signal);
            return true;
        }
        catch (Exception ex) { feedback.Text = Text.Get("Error") + "\n" + ex.Message; return false; }
        finally { busy = false; body.IsEnabled = true; UpdateDirty(); }
    }
    public async Task<bool> RequestLeaveAsync()
    {
        if (busy) return false;
        if (DraftFingerprint() == baseline) return true;
        var result = MessageBox.Show(Window.GetWindow(this), Text.Get("DirtyPrompt"), "Barback", MessageBoxButton.YesNoCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        return result == MessageBoxResult.No || result == MessageBoxResult.Yes && await SaveAsync(null);
    }
    public void Dispose() { if (disposed) return; disposed = true; supervisor.Changed -= SupervisorChanged; }
}
