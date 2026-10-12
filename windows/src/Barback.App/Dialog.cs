namespace Barback.App;

public enum DialogTone { Question, Warning, Danger, Error, Info }

/// <summary>
/// In-app replacement for MessageBox. A WPF window follows the Fluent theme (dark mode, high contrast, title bar) instead of
/// popping a light Win32 box over a dark workbench, and its buttons name the action ("Delete", "Force stop") rather than
/// "OK". Failures before the theme exists (OS check, elevation, single instance, unreadable data) still use MessageBox.
/// </summary>
public static class Dialog
{
    private sealed record Choice(string Key, bool Primary);

    /// <summary>Confirm / cancel. Cancel stays the default button, as it was with the MessageBox prompts this replaces.</summary>
    public static bool Confirm(string message, string confirmKey = "OK", DialogTone tone = DialogTone.Question, Window? owner = null)
        => Show(owner, message, tone, [new(confirmKey, true), new("Cancel", false)], cancelIndex: 1, defaultIndex: 1) == 0;

    public static void Notify(string message, DialogTone tone = DialogTone.Info, Window? owner = null)
        => Show(owner, message, tone, [new("OK", true)], cancelIndex: 0, defaultIndex: 0);

    /// <summary>Unsaved edits: true = save, false = discard, null = keep editing (also Esc and the close button).</summary>
    public static bool? SaveChanges(Window? owner) =>
        Show(owner, Text.Get("DirtyPrompt"), DialogTone.Question, [new("Save", true), new("Discard", false), new("KeepEditing", false)], cancelIndex: 2, defaultIndex: 0) switch
        {
            0 => true,
            1 => false,
            _ => null
        };

    private static int Show(Window? owner, string message, DialogTone tone, Choice[] choices, int cancelIndex, int defaultIndex)
    {
        owner ??= Application.Current?.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive)
            ?? (Application.Current?.MainWindow is { IsVisible: true } main ? main : null);
        if (owner is { IsVisible: false }) owner = null; // an unshown owner cannot own a dialog
        int result = cancelIndex;
        var window = new Window
        {
            Title = "Barback", SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            MinWidth = 380, MaxWidth = 560, ShowInTaskbar = owner is null,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            FontFamily = new System.Windows.Media.FontFamily("Segoe UI"), FontSize = 14
        };
        if (owner is not null) window.Owner = owner;
        window.SetResourceReference(Window.BackgroundProperty, "SurfaceBrush");
        window.SetResourceReference(Window.ForegroundProperty, "PrimaryTextBrush");

        var (glyph, brush) = tone switch
        {
            DialogTone.Warning => ("", "WarningBrush"),
            DialogTone.Danger => ("", "DangerBrush"),
            DialogTone.Error => ("", "DangerBrush"),
            DialogTone.Info => ("", "AccentBrush"),
            _ => ("", "AccentBrush")
        };
        var root = new Grid { Margin = new(24, 22, 24, 18) };
        root.RowDefinitions.Add(new()); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var body = new DockPanel();
        var icon = new TextBlock { Text = glyph, Style = (Style)Application.Current!.FindResource("Symbol"), FontSize = 22, Margin = new(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Top };
        icon.SetResourceReference(TextBlock.ForegroundProperty, brush);
        DockPanel.SetDock(icon, Dock.Left); body.Children.Add(icon);
        body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 460, LineHeight = 20 });
        root.Children.Add(body);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new(0, 22, 0, 0) };
        Grid.SetRow(actions, 1); root.Children.Add(actions);
        var buttons = new List<Button>();
        for (int i = 0; i < choices.Length; i++)
        {
            int index = i; var choice = choices[i];
            var button = new Button { Content = Text.Get(choice.Key), MinWidth = 96, Margin = new(8, 0, 0, 0), IsCancel = i == cancelIndex, IsDefault = i == defaultIndex };
            button.Style = (Style)Application.Current.FindResource(choice.Primary ? "AccentButton" : "WorkbenchButton");
            if (choice.Primary && tone == DialogTone.Danger)
            {
                button.SetResourceReference(Control.BackgroundProperty, "DangerBrush");
                button.SetResourceReference(Control.ForegroundProperty, "AccentForegroundBrush");
            }
            button.Click += (_, _) => { result = index; window.Close(); };
            actions.Children.Add(button); buttons.Add(button);
        }
        window.Content = root;
        window.Loaded += (_, _) => buttons[defaultIndex].Focus();
        window.ShowDialog();
        return result;
    }
}
