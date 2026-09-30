namespace Barback.App;

public sealed class LogWindow : Window
{
    public LogWindow(string directory, int encoding)
    {
        Title = Text.Get("Output"); Width = 900; Height = 600; MinWidth = 480; MinHeight = 360;
        SetResourceReference(BackgroundProperty, "DetailBrush"); SetResourceReference(ForegroundProperty, "PrimaryTextBrush");
        var view = new LogView(directory, encoding) { Margin = new(20) }; Content = view;
        Closed += (_, _) => view.Dispose();
    }
}
