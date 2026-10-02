using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Text;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Barback.Core;
using Barback.Windows;
namespace Barback.App;

public sealed class LogView : UserControl, IDisposable
{
    private const int ReadBytesPerCycle = 1024 * 1024, SkipThresholdBytes = 8 * 1024 * 1024;
    private sealed record SearchMatch(string File, long Offset, string Needle, (uint Volume, ulong Index) Identity)
    {
        public override string ToString() => $"{Path.GetFileName(File)} : {Offset}";
    }
    /// <summary>Reference identity keeps duplicate lines distinguishable; <see cref="Sequence"/> restores order when copying a selection.</summary>
    private sealed class LogLineItem(string text)
    {
        private static long next;
        public string Text { get; } = text;
        public long Sequence { get; } = Interlocked.Increment(ref next);
        public override string ToString() => Text;
    }
    /// <summary>Raises one Reset for bulk changes (eviction, large reads) and per-item Add notifications for small ones.</summary>
    private sealed class LogLineCollection : ObservableCollection<LogLineItem>
    {
        private const int IncrementalLimit = 500;
        public void Apply(int removeFromStart, IReadOnlyList<LogLineItem> fresh, LogLineItem? oldPartial, LogLineItem? newPartial)
        {
            if (removeFromStart == 0 && fresh.Count <= IncrementalLimit)
            {
                if (oldPartial is not null) RemoveAt(Count - 1); // the unfinished line is always last
                foreach (var item in fresh) Add(item);
                if (newPartial is not null) Add(newPartial);
                return;
            }
            CheckReentrancy();
            if (oldPartial is not null) Items.RemoveAt(Items.Count - 1);
            if (removeFromStart > 0) ((List<LogLineItem>)Items).RemoveRange(0, removeFromStart);
            foreach (var item in fresh) Items.Add(item);
            if (newPartial is not null) Items.Add(newPartial);
            OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count))); OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
            OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
        }
    }
    /// <summary>One step of a background read, applied in order on the UI thread.</summary>
    private readonly record struct ReadEvent(string? Text, string? Marker);
    private string directory;
    private int encoding;
    private readonly LogLineBuffer buffer = new();
    private readonly LogLineCollection items = [];
    private readonly ListBox output = new()
    {
        SelectionMode = SelectionMode.Extended, FontFamily = new FontFamily("Consolas"), FontSize = 12, Margin = new(0), Padding = new(0, 6, 0, 6),
        HorizontalContentAlignment = HorizontalAlignment.Left, BorderThickness = new(1)
    };
    private readonly TextBox search = new();
    private readonly ComboBox stream = new() { ItemsSource = new[] { "stdout", "stderr" }, SelectedIndex = 0, MinWidth = 85, Margin = new(0, 0, 8, 0) };
    private readonly CheckBox follow = new() { Content = Text.Get("Follow"), IsChecked = true, Margin = new(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock status = new() { Margin = new(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private FileStream? current;
    private (uint Volume, ulong Index) identity;
    private IncrementalLogDecoder decoder;
    private string? currentStream;
    private bool loading, closed;
    private long appliedAdded, appliedRemoved;
    private LogLineItem? partialItem;
    private bool adjusting;
    private (string Directory, int Encoding, string Label)? pendingSwitch;
    private CancellationTokenSource? searching;
    public Action? OpenSeparate { get; set; }
    public LogView(string directory, int encoding)
    {
        this.directory = directory; this.encoding = encoding; decoder = new(encoding);
        status.Style = (Style)FindResource("Caption"); search.Style = (Style)FindResource("WorkbenchInput");
        search.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("SearchLoaded")); search.ToolTip = Text.Get("SearchLoaded");
        output.SetResourceReference(BackgroundProperty, "SurfaceBrush"); output.SetResourceReference(ForegroundProperty, "PrimaryTextBrush");
        output.SetResourceReference(BorderBrushProperty, "LineBrush"); output.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("Output"));
        ConfigureList();
        var root = new DockPanel(); Content = root;
        var controls = new StackPanel { Margin = new(0, 0, 0, 10) }; DockPanel.SetDock(controls, Dock.Top); root.Children.Add(controls);
        var toolbar = new WrapPanel { Margin = new(0, 0, 0, 10) }; controls.Children.Add(toolbar); toolbar.Children.Add(stream); toolbar.Children.Add(follow);
        var more = new Button { Content = "···", Style = (Style)FindResource("QuietButton"), ToolTip = Text.Get("OutputOptions") }; more.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("OutputOptions")); toolbar.Children.Add(more);
        more.Click += (_, _) => ShowOptions(more);
        var searchRow = new Grid(); searchRow.ColumnDefinitions.Add(new()); searchRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); searchRow.Children.Add(search); controls.Children.Add(searchRow);
        var next = new Button { Content = "↓", Style = (Style)FindResource("QuietButton"), ToolTip = Text.Get("SearchNext"), Margin = new(6, 0, 0, 0) }; Grid.SetColumn(next, 1); searchRow.Children.Add(next); next.Click += (_, _) => FindNext();
        next.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, Text.Get("SearchNext"));
        DockPanel.SetDock(status, Dock.Bottom); root.Children.Add(status); root.Children.Add(output);
        output.PreviewMouseWheel += (_, e) => { if (e.Delta > 0) follow.IsChecked = false; };
        output.PreviewKeyDown += OutputKeyDown;
        output.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, e) => { if (!adjusting && e.VerticalChange < 0 && e.ExtentHeightChange == 0) follow.IsChecked = false; }));
        follow.Checked += (_, _) => ScrollToEnd();
        search.KeyDown += (_, e) => { if (e.Key == Key.Enter) { FindNext(); e.Handled = true; } };
        stream.SelectionChanged += async (_, _) => { ResetView(); await RefreshAsync(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { search.Focus(); e.Handled = true; } };
        timer.Tick += async (_, _) => await RefreshAsync();
        Loaded += async (_, _) => { if (!closed) { timer.Start(); await RefreshAsync(); } };
        Unloaded += (_, _) => timer.Stop();
        IsVisibleChanged += async (_, _) => { if (IsVisible && !closed) { timer.Start(); await RefreshAsync(); } else timer.Stop(); };
    }
    /// <summary>A virtualizing list of single-line rows: only the visible rows are ever laid out, however much output is loaded.</summary>
    private void ConfigureList()
    {
        output.ItemsSource = items;
        VirtualizingPanel.SetIsVirtualizing(output, true); VirtualizingPanel.SetVirtualizationMode(output, VirtualizationMode.Recycling);
        ScrollViewer.SetCanContentScroll(output, true); ScrollViewer.SetHorizontalScrollBarVisibility(output, ScrollBarVisibility.Auto);
        var text = new FrameworkElementFactory(typeof(TextBlock)); text.SetBinding(TextBlock.TextProperty, new Binding(nameof(LogLineItem.Text)) { Mode = BindingMode.OneTime });
        text.SetValue(TextBlock.TextWrappingProperty, TextWrapping.NoWrap); text.SetValue(TextBlock.PaddingProperty, new Thickness(10, 0, 10, 0));
        output.ItemTemplate = new DataTemplate { VisualTree = text };
        var rowStyle = new Style(typeof(ListBoxItem)); rowStyle.Setters.Add(new Setter(PaddingProperty, new Thickness(0))); rowStyle.Setters.Add(new Setter(BorderThicknessProperty, new Thickness(0)));
        output.ItemContainerStyle = rowStyle;
        var menu = new ContextMenu();
        var copySelected = new MenuItem { Header = Text.Get("CopySelectedLines") }; copySelected.Click += (_, _) => CopySelected(); menu.Items.Add(copySelected);
        var copyAll = new MenuItem { Header = Text.Get("CopyLoadedOutput") }; copyAll.Click += (_, _) => CopyAll(); menu.Items.Add(copyAll);
        output.ContextMenu = menu;
    }
    private void OutputKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is Key.PageUp or Key.Up or Key.Home) follow.IsChecked = false;
        if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control) { CopySelected(); e.Handled = true; }
    }
    private void CopySelected()
    {
        var lines = output.SelectedItems.Cast<LogLineItem>().OrderBy(i => i.Sequence).Select(i => i.Text).ToArray();
        if (lines.Length > 0) TryCopy(string.Join(Environment.NewLine, lines));
    }
    private void CopyAll() { if (items.Count > 0) TryCopy(string.Join(Environment.NewLine, items.Select(i => i.Text))); }
    private static void TryCopy(string text)
    {
        // The clipboard can be held by another process for a moment; copying is best effort.
        try { Clipboard.SetText(text); } catch (System.Runtime.InteropServices.COMException) { }
    }
    private ScrollViewer? FindScroller()
    {
        // Not cached: a theme change re-applies the template and replaces the ScrollViewer.
        static ScrollViewer? Find(DependencyObject root)
        {
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            {
                var child = VisualTreeHelper.GetChild(root, i);
                if (child is ScrollViewer viewer) return viewer;
                if (Find(child) is { } nested) return nested;
            }
            return null;
        }
        return Find(output);
    }
    private void ScrollToEnd() { if (items.Count > 0) output.ScrollIntoView(items[^1]); }
    public void FocusSearch() => search.Focus();
    /// <summary>Searches the loaded lines only; the disk-wide search is a separate action.</summary>
    private void FindNext()
    {
        if (search.Text.Length == 0 || items.Count == 0) return;
        follow.IsChecked = false;
        var needle = search.Text; int start = output.SelectedIndex + 1, total = items.Count;
        for (int offset = 0; offset < total; offset++)
        {
            int index = (start + offset) % total;
            if (!items[index].Text.Contains(needle, StringComparison.OrdinalIgnoreCase)) continue;
            output.SelectedItems.Clear(); output.SelectedIndex = index; output.ScrollIntoView(items[index]); output.Focus();
            return;
        }
        status.Text = Text.Get("NoMatch");
    }
    /// <summary>Same program, new run (service restart): keep the earlier output and continue below a separator.</summary>
    public void SwitchRun(string newDirectory, int newEncoding, string label)
    {
        if (closed) return;
        pendingSwitch = (newDirectory, newEncoding, label);
        _ = RefreshAsync();
    }
    private void ApplyPendingSwitch()
    {
        if (pendingSwitch is not var (newDirectory, newEncoding, label)) return;
        pendingSwitch = null;
        current?.Dispose(); current = null; directory = newDirectory; encoding = newEncoding; decoder = new(newEncoding);
        buffer.AppendMarker("──── " + label + " ────"); SyncView();
    }
    private void ResetView()
    {
        buffer.Clear(); items.Clear(); partialItem = null; appliedAdded = buffer.TotalAdded; appliedRemoved = buffer.TotalRemoved;
    }
    /// <summary>Brings the list in line with the buffer using the buffer's monotonic counters, however many operations happened since the last sync.</summary>
    private void SyncView()
    {
        long addedNow = buffer.TotalAdded - appliedAdded, removedNow = buffer.TotalRemoved - appliedRemoved;
        int shown = items.Count - (partialItem is null ? 0 : 1);
        int remove = (int)Math.Min(removedNow, shown), fresh = (int)Math.Min(addedNow, buffer.Count);
        var partialText = buffer.Partial;
        if (remove == 0 && fresh == 0 && partialText == partialItem?.Text) return;
        var added = new LogLineItem[fresh];
        for (int i = 0; i < fresh; i++) added[i] = new(buffer.Lines[buffer.Count - fresh + i]);
        var newPartial = partialText is null ? null : new LogLineItem(partialText);
        double offset = FindScroller()?.VerticalOffset ?? 0;
        // Our own list changes and scrolling must not be mistaken for the reader scrolling up and switching Follow off.
        adjusting = true; Dispatcher.BeginInvoke(() => adjusting = false, DispatcherPriority.ContextIdle);
        items.Apply(remove, added, partialItem, newPartial);
        partialItem = newPartial; appliedAdded = buffer.TotalAdded; appliedRemoved = buffer.TotalRemoved;
        if (follow.IsChecked == true) ScrollToEnd();
        else if (remove > 0 || fresh > 500) FindScroller()?.ScrollToVerticalOffset(Math.Max(0, offset - remove)); // a Reset rewinds the list; keep the reader's place
    }
    private void ShowOptions(FrameworkElement target)
    {
        var menu = new ContextMenu { PlacementTarget = target, Placement = PlacementMode.Bottom };
        void Item(string key, Func<Task> action) { var item = new MenuItem { Header = Text.Get(key) }; item.Click += async (_, _) => await MainWindow.RunGuardedAsync(action); menu.Items.Add(item); }
        if (OpenSeparate is not null) Item("OpenSeparate", () => { OpenSeparate(); return Task.CompletedTask; });
        Item("FullSearch", SearchDiskAsync); Item("CancelSearch", () => { searching?.Cancel(); return Task.CompletedTask; });
        Item("OpenData", () => { ShellIntegration.Open(directory); return Task.CompletedTask; });
        Item("ExportCurrentSegment", () => ExportAsync(allSegments: false));
        Item("ExportAllSegments", () => ExportAsync(allSegments: true));
        menu.IsOpen = true;
    }
    /// <summary>Segments of one stream in time order: <c>.N</c> … <c>.1</c>, then the active file.</summary>
    private static string[] SegmentFiles(string directory, string stream)
    {
        var pattern = new System.Text.RegularExpressions.Regex("^" + stream + @"\.log(?:\.(?<n>[0-9]+))?$");
        return Directory.GetFiles(directory, stream + ".log*")
            .Select(path => (Path: path, Match: pattern.Match(Path.GetFileName(path)))).Where(x => x.Match.Success)
            .OrderByDescending(x => x.Match.Groups["n"].Success ? int.Parse(x.Match.Groups["n"].Value) : 0).Select(x => x.Path).ToArray();
    }
    private async Task ExportAsync(bool allSegments)
    {
        var selected = (string)stream.SelectedItem;
        var sources = allSegments ? SegmentFiles(directory, selected) : [Path.GetFullPath(Path.Combine(directory, selected + ".log"))];
        var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Raw log bytes|*.log", FileName = selected + (allSegments ? "-all.log" : ".log") };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        var destination = Path.GetFullPath(dialog.FileName);
        if (sources.Any(source => Path.GetFullPath(source).Equals(destination, StringComparison.OrdinalIgnoreCase))) throw new IOException(Text.Get("ExportSameFile"));
        using var targetFile = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 65536, true);
        foreach (var path in sources)
        {
            // A segment can be rotated away or cleaned while exporting; export what still exists.
            try { using var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true); await source.CopyToAsync(targetFile); }
            catch (FileNotFoundException) { }
        }
    }
    public void Dispose()
    {
        if (closed) return; closed = true; timer.Stop(); searching?.Cancel();
        if (!loading) { current?.Dispose(); current = null; }
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
            var resultsWindow = new Window { Title = Text.Get("FullSearch"), Width = 700, Height = 500, Owner = Window.GetWindow(this), Content = results };
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
            ApplyPendingSwitch();
            var path = Path.Combine(directory, selected + ".log");
            bool changedStream = currentStream != selected;
            if (!File.Exists(path))
            {
                if (changedStream) { current?.Dispose(); current = null; currentStream = selected; decoder = new(encoding); ResetView(); }
                status.Text = Text.Get("NoOutput"); return;
            }
            var events = await Task.Run(async () =>
            {
                var result = new List<ReadEvent>();
                using var candidate = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
                var nextIdentity = Native.FileIdentity(candidate.SafeFileHandle);
                async Task ReadChunkAsync(FileStream file)
                {
                    // Followers that fall far behind jump to the tail instead of chasing a high-volume writer.
                    long behind = file.Length - file.Position;
                    if (behind > SkipThresholdBytes)
                    {
                        long start = file.Length - SkipThresholdBytes; if (encoding is 1200 or 1201) start -= start % 2;
                        long skipped = start - file.Position; file.Position = start; decoder = new(encoding);
                        result.Add(new(null, Text.Format("SkippedOutput", Math.Max(1, skipped / 1048576))));
                    }
                    var bytes = new byte[65536]; int read = 0, n;
                    while (read < ReadBytesPerCycle && (n = await file.ReadAsync(bytes)) > 0) { read += n; result.Add(new(decoder.Decode(bytes.AsSpan(0, n)), null)); }
                }
                if (changedStream) { current?.Dispose(); current = null; decoder = new(encoding); currentStream = selected; }
                if (current is not null && identity != nextIdentity)
                {
                    await ReadChunkAsync(current);
                    // Finish draining the renamed segment over successive bounded updates before opening its successor.
                    if (current.Position < current.Length) return result;
                    current.Dispose(); current = null; decoder = new(encoding); result.Add(new(null, Text.Get("LogRotated")));
                }
                if (current is null) { current = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true); identity = Native.FileIdentity(current.SafeFileHandle); }
                await ReadChunkAsync(current); return result;
            });
            if (closed || (string)stream.SelectedItem != selected) return;
#if DEBUG
            var uiTime = System.Diagnostics.Stopwatch.StartNew();
#endif
            if (changedStream) ResetView();
            bool any = false;
            foreach (var step in events)
            {
                if (step.Marker is not null) { buffer.AppendMarker(step.Marker); any = true; }
                else if (step.Text is { Length: > 0 }) { buffer.Append(step.Text); any = true; }
            }
            if (any) SyncView();
#if DEBUG
            // Acceptance budget: one UI refresh stays under 50 ms (see windows-test-runbook, high-throughput log viewing).
            System.Diagnostics.Debug.WriteLine($"LogView refresh: {uiTime.Elapsed.TotalMilliseconds:F1} ms, {events.Count} steps, {items.Count} rows");
#endif
            status.Text = (File.Exists(path + ".gaps") ? Text.Get("LogIncomplete") + " " : "") + (any && follow.IsChecked != true ? Text.Get("NewOutput") : Text.Get("LoadedSearchHint"));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { status.Text = Text.Get("NotLoaded") + ": " + ex.Message; }
        finally { loading = false; if (closed) { current?.Dispose(); current = null; } }
    }
}
