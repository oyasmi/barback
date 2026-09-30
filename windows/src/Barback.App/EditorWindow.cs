using System.ComponentModel;
using Barback.Core;

namespace Barback.App;

// Auxiliary callers use the same editor as the workbench, including draft protection.
public sealed class EditorWindow : Window
{
    private readonly EditorView editor;
    private bool allowClose;
    public EditorWindow(Supervisor supervisor, ProgramConfig config)
    {
        Title = Text.Get("Edit") + " — " + config.Name; Width = 920; Height = 740; MinWidth = 640; MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        editor = new(supervisor, config); Content = editor; editor.CancelRequested += (_, _) => Close();
        Closing += OnClosing; Closed += (_, _) => editor.Dispose();
    }
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (allowClose) return;
        e.Cancel = true;
        if (await editor.RequestLeaveAsync()) { allowClose = true; Close(); }
    }
}
