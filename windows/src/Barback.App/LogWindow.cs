using System.Text;
using System.Windows.Threading;
using Barback.Core;
using Barback.Windows;
namespace Barback.App;

public sealed class LogWindow : Window
{
    private sealed record SearchMatch(string File, long Offset, string Needle, (uint Volume, ulong Index) Identity)
    {
        public override string ToString() => $"{Path.GetFileName(File)} : {Offset}";
    }
    private readonly string directory;
    private readonly int encoding;
    private readonly TextBox output = new() { IsReadOnly = true, AcceptsReturn = true, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new(12) };
    private readonly TextBox search = new() { Width = 180 };
    private readonly ComboBox stream = new() { ItemsSource = new[] { "stdout", "stderr" }, SelectedIndex = 0, Margin = new(8) };
    private readonly CheckBox follow = new() { Content = Text.Get("Follow"), IsChecked = true, Margin = new(8) };
    private readonly TextBlock status = new() { Margin = new(12) };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private FileStream? current;
    private (uint Volume, ulong Index) identity;
    private IncrementalLogDecoder decoder;
    private string? currentStream;
    private bool loading, closed;
    private int retainedLines;
    private CancellationTokenSource? searching;
    public LogWindow(string directory, int encoding)
    {
        this.directory = directory; this.encoding = encoding; decoder = new(encoding); Title = Text.Get("Logs"); Width = 900; Height = 600;
        var root = new DockPanel(); Content = root; var controls = new WrapPanel { Margin = new(12) }; DockPanel.SetDock(controls, Dock.Top); root.Children.Add(controls);
        controls.Children.Add(stream); controls.Children.Add(follow); controls.Children.Add(search); controls.Children.Add(MainWindow.Button("Search", () => { var start = Math.Min(output.Text.Length, output.SelectionStart + output.SelectionLength); var at = output.Text.IndexOf(search.Text, start, StringComparison.OrdinalIgnoreCase); if (at >= 0) { output.Select(at, search.Text.Length); output.ScrollToLine(output.GetLineIndexFromCharacterIndex(at)); } return Task.CompletedTask; }));
        controls.Children.Add(MainWindow.Button("FullSearch", SearchDiskAsync));
        controls.Children.Add(MainWindow.Button("CancelSearch", () => { searching?.Cancel(); return Task.CompletedTask; }));
        controls.Children.Add(MainWindow.Button("OpenData", () => { ShellIntegration.Open(directory); return Task.CompletedTask; }));
        controls.Children.Add(MainWindow.Button("Export", async () => { var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Raw log bytes|*.log", FileName = stream.SelectedItem + ".log" }; if (dialog.ShowDialog(this) == true) { using var source = new FileStream(Path.Combine(directory, stream.SelectedItem + ".log"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true); using var target = new FileStream(dialog.FileName, FileMode.Create, FileAccess.Write, FileShare.None, 65536, true); await source.CopyToAsync(target); } }));
        DockPanel.SetDock(status, Dock.Bottom); root.Children.Add(status); root.Children.Add(output);
        output.PreviewMouseWheel += (_, e) => { if (e.Delta > 0) follow.IsChecked = false; };
        timer.Tick += async (_, _) => await RefreshAsync(); IsVisibleChanged += async (_, _) => { if (IsVisible) { timer.Start(); await RefreshAsync(); } else timer.Stop(); };
        Closed += (_, _) => { timer.Stop(); closed = true; searching?.Cancel(); if (!loading) current?.Dispose(); };
    }

    private async Task SearchDiskAsync()
    {
        if (search.Text.Length == 0 || search.Text.Length > 1024) return;
        searching?.Cancel(); searching = new(); var cancellation = searching.Token; var needle = search.Text; var selected = (string)stream.SelectedItem;
        try
        {
            var matches = await Task.Run(async () =>
            {
                var result = new List<SearchMatch>();
                var files = Directory.GetFiles(directory, selected + ".log*").Where(p => !p.EndsWith(".gaps", StringComparison.Ordinal)).Order().ToArray();
                foreach (var file in files)
                {
                    cancellation.ThrowIfCancellationRequested();
                    using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
                    var fileIdentity = Native.FileIdentity(input.SafeFileHandle);
                    var incremental = new IncrementalLogDecoder(encoding); var bytes = new byte[65536]; string carry = ""; long offset = 0; int n;
                    while ((n = await input.ReadAsync(bytes, cancellation)) > 0)
                    {
                        var block = carry + incremental.Decode(bytes.AsSpan(0, n)); var start = 0;
                        while ((start = block.IndexOf(needle, start, StringComparison.OrdinalIgnoreCase)) >= 0)
                        {
                            result.Add(new(file, offset - carry.Length + start, needle, fileIdentity)); start += needle.Length;
                            if (result.Count >= 1000) return result;
                        }
                        offset += block.Length - carry.Length; carry = block[Math.Max(0, block.Length - needle.Length + 1)..];
                    }
                }
                return result;
            }, cancellation);
            if (closed) return;
            var results = new ListBox { ItemsSource = matches, Margin = new(12) };
            var resultsWindow = new Window { Title = Text.Get("FullSearch"), Width = 700, Height = 500, Owner = this, Content = results };
            results.MouseDoubleClick += async (_, _) => { if (results.SelectedItem is SearchMatch match) await OpenMatchAsync(match, resultsWindow, cancellation); };
            results.KeyDown += async (_, e) => { if (e.Key == System.Windows.Input.Key.Enter && results.SelectedItem is SearchMatch match) { e.Handled = true; await OpenMatchAsync(match, resultsWindow, cancellation); } };
            resultsWindow.Show();
        }
        catch (OperationCanceledException) { }
    }
    private async Task OpenMatchAsync(SearchMatch match, Window owner, CancellationToken cancellation)
    {
        try
        {
            long first = Math.Max(0, match.Offset - 4096), last = match.Offset + match.Needle.Length + 4096;
            var context = await Task.Run(async () =>
            {
                using var input = new FileStream(match.File, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
                if (Native.FileIdentity(input.SafeFileHandle) != match.Identity) throw new IOException(Text.Get("SearchChanged"));
                var decoding = new IncrementalLogDecoder(encoding); var bytes = new byte[65536]; var text = new StringBuilder(); long offset = 0; int count;
                while (offset < last && (count = await input.ReadAsync(bytes, cancellation)) > 0)
                {
                    var block = decoding.Decode(bytes.AsSpan(0, count));
                    int from = (int)Math.Clamp(first - offset, 0, block.Length), to = (int)Math.Clamp(last - offset, 0, block.Length);
                    if (to > from) text.Append(block.AsSpan(from, to - from));
                    offset += block.Length;
                }
                return text.ToString();
            }, cancellation);
            if (closed || !owner.IsVisible) return;
            int at = (int)(match.Offset - first);
            if (at + match.Needle.Length > context.Length || !context.AsSpan(at, match.Needle.Length).Equals(match.Needle.AsSpan(), StringComparison.OrdinalIgnoreCase)) throw new IOException(Text.Get("SearchChanged"));
            var view = new TextBox { Text = context, IsReadOnly = true, AcceptsReturn = true, Margin = new(12), HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            var window = new Window { Title = Path.GetFileName(match.File), Owner = owner, Width = 800, Height = 500, Content = view };
            window.Loaded += (_, _) => { view.Select(at, match.Needle.Length); view.ScrollToLine(view.GetLineIndexFromCharacterIndex(at)); view.Focus(); };
            window.Show();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { if (!closed && owner.IsVisible) MessageBox.Show(owner, ex.Message, "Barback", MessageBoxButton.OK, MessageBoxImage.Information); }
    }
    private async Task RefreshAsync()
    {
        if (loading || !IsVisible || closed) return; loading = true;
        var selected = (string)stream.SelectedItem;
        try
        {
            var path = Path.Combine(directory, selected + ".log");
            if (!File.Exists(path)) { status.Text = Text.Get("NoOutput"); return; }
            bool changedStream = currentStream != selected;
            var text = await Task.Run(async () =>
            {
                using var candidate = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
                var nextIdentity = Native.FileIdentity(candidate.SafeFileHandle);
                var builder = new StringBuilder();
                async Task ReadChunkAsync(FileStream file)
                {
                    var bytes = new byte[65536]; int read = 0, n;
                    while (read < 256 * 1024 && (n = await file.ReadAsync(bytes)) > 0) { read += n; builder.Append(decoder.Decode(bytes.AsSpan(0, n))); }
                }
                if (changedStream) { current?.Dispose(); current = null; decoder = new(encoding); currentStream = selected; }
                if (current is not null && identity != nextIdentity)
                {
                    await ReadChunkAsync(current);
                    // Finish draining the renamed segment over successive bounded updates before opening its successor.
                    if (current.Position < current.Length) return builder.ToString();
                    current.Dispose(); current = null; decoder = new(encoding); builder.AppendLine("\n[log rotated]");
                }
                if (current is null)
                {
                    current = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true); identity = Native.FileIdentity(current.SafeFileHandle);
                    if (current.Length > 8 * 1024 * 1024) { long start = current.Length - 8 * 1024 * 1024; if (encoding == 1200) start -= start % 2; current.Position = start; builder.AppendLine("[showing recent output]"); }
                }
                await ReadChunkAsync(current); return builder.ToString();
            });
            if (closed) return;
            if (changedStream) { output.Clear(); retainedLines = 0; }
            if (text.Length > 0)
            {
                // Long lines are displayed in bounded chunks; original file bytes are unchanged.
                var display = string.Join('\n', text.Split('\n').SelectMany(line => Enumerable.Range(0, Math.Max(1, (line.Length + 65535) / 65536)).Select(i => line.Substring(i * 65536, Math.Min(65536, line.Length - i * 65536)))));
                var offset = output.VerticalOffset; output.AppendText(display); retainedLines += display.Count(c => c == '\n');
                if (output.Text.Length > 8 * 1024 * 1024 || retainedLines > 10000)
                {
                    var all = output.Text; var start = Math.Max(0, all.Length - 8 * 1024 * 1024); int excess = Math.Max(0, retainedLines - 10000);
                    int at = 0; while (excess-- > 0 && (at = all.IndexOf('\n', at) + 1) > 0) start = Math.Max(start, at);
                    output.Text = all[start..]; retainedLines = output.Text.Count(c => c == '\n');
                }
                if (follow.IsChecked == true) output.ScrollToEnd(); else output.ScrollToVerticalOffset(offset);
            }
            status.Text = File.Exists(path + ".gaps") ? "Log incomplete; see .gaps file. Search covers loaded output only." : "Search covers loaded output only.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { status.Text = Text.Get("NotLoaded") + ": " + ex.Message; }
        finally { loading = false; if (closed) { current?.Dispose(); current = null; } }
    }
}
