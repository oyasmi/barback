using System.Threading.Channels;
using System.Text;
namespace Barback.Core;

/// <summary>Raw byte capture; bounded memory, one file writer, independent pipe drainer.</summary>
public sealed class LogCollector : IAsyncDisposable
{
    private const int ChunkSize = 16384;
    private readonly Channel<byte[]> queue = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(64) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly string path;
    private readonly long segmentBytes;
    private readonly int segments;
    private readonly Action<long> loss;
    private readonly LogQuota? globalQuota, runQuota;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task reader;
    private readonly Task writer;
    private long dropped;
    private long notified;
    private bool disposed;
    public long DroppedBytes => Interlocked.Read(ref dropped);
    public LogCollector(Stream input, string path, long segmentBytes, int segments, Action<long> loss, LogQuota? globalQuota = null, LogQuota? runQuota = null)
    {
        this.globalQuota = globalQuota; this.runQuota = runQuota; this.path = path; this.segmentBytes = segmentBytes; this.segments = segments; this.loss = loss;
        // Probe before process creation. Write failure during a run cannot stop pipe draining.
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using (new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) { }
        writer = WriteAsync(); reader = ReadAsync(input);
    }
    private void Drop(long count)
    {
        var total = Interlocked.Add(ref dropped, count);
        if (Interlocked.CompareExchange(ref notified, total, 0) == 0) loss(total);
    }
    private async Task ReadAsync(Stream stream)
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var bytes = new byte[ChunkSize]; var n = await stream.ReadAsync(bytes, lifetime.Token);
                if (n == 0) break;
                if (n != bytes.Length) Array.Resize(ref bytes, n);
                if (!queue.Writer.TryWrite(bytes)) Drop(n);
            }
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { }
        finally { queue.Writer.TryComplete(); await stream.DisposeAsync(); }
    }
    private FileStream Open() => new(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.Asynchronous);
    private void Rotate()
    {
        if (segments == 0) { DeleteSegment(path); return; }
        DeleteSegment(path + "." + segments);
        for (int i = segments - 1; i >= 1; i--) if (File.Exists(path + "." + i)) File.Move(path + "." + i, path + "." + (i + 1), true);
        if (File.Exists(path)) File.Move(path, path + ".1", true);
    }
    private void Release(long bytes) { globalQuota?.Release(bytes); runQuota?.Release(bytes); }
    private void DeleteSegment(string file)
    {
        if (!File.Exists(file)) return; long bytes = new FileInfo(file).Length; File.Delete(file); Release(bytes);
    }
    private enum ReserveResult { Ok, RunLimit, GlobalLimit }
    /// <summary>The global budget is only reported as pressured by the caller once it knows rotating its own segments cannot help.</summary>
    private ReserveResult Reserve(long bytes)
    {
        if (globalQuota?.TryReserve(bytes, reportPressure: false) == false) return ReserveResult.GlobalLimit;
        if (runQuota?.TryReserve(bytes, reportPressure: false) == false) { globalQuota?.Release(bytes); return ReserveResult.RunLimit; }
        return ReserveResult.Ok;
    }
    private async Task WriteAsync()
    {
        FileStream? output = null; var retry = DateTime.MinValue; long marked = 0; bool runLimited = false;
        try
        {
            await foreach (var bytes in queue.Reader.ReadAllAsync())
            {
                if (runLimited || DateTime.UtcNow < retry) { Drop(bytes.Length); continue; }
                bool reserved = false;
                try
                {
                    output ??= Open();
                    if (output.Length + bytes.Length > segmentBytes) { await output.DisposeAsync(); output = null; Rotate(); output = Open(); }
                    var reservation = Reserve(bytes.Length);
                    if (reservation == ReserveResult.GlobalLimit)
                    {
                        // Free this stream's own rotated segments first, oldest first.
                        for (int segment = segments; segment >= 1 && reservation == ReserveResult.GlobalLimit; segment--)
                        {
                            var old = path + "." + segment;
                            if (!File.Exists(old)) continue;
                            DeleteSegment(old); reservation = Reserve(bytes.Length);
                        }
                        if (reservation == ReserveResult.GlobalLimit)
                        {
                            // Nothing of ours left to free: ask for maintenance and drop this chunk; later chunks retry.
                            globalQuota?.ReportPressure(); Drop(bytes.Length); continue;
                        }
                    }
                    if (reservation == ReserveResult.RunLimit)
                    {
                        // One-shot history is truncated, not rotated: stop writing and leave a single marker.
                        runLimited = true; Drop(bytes.Length);
                        await File.AppendAllTextAsync(path + ".gaps", $"{DateTimeOffset.UtcNow:O} run-output-limit reached at {runQuota?.UsedBytes}\n");
                        continue;
                    }
                    reserved = true;
                    if (DroppedBytes > marked)
                    {
                        // Separate sidecar preserves arbitrary byte encodings in business output.
                        if (File.Exists(path + ".gaps") && new FileInfo(path + ".gaps").Length > 65536) File.Delete(path + ".gaps");
                        await File.AppendAllTextAsync(path + ".gaps", $"{DateTimeOffset.UtcNow:O} dropped-total={DroppedBytes}\n");
                        marked = DroppedBytes;
                    }
                    await output.WriteAsync(bytes);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    if (reserved) Release(bytes.Length);
                    Drop(bytes.Length);
                    if (output is not null) { try { await output.DisposeAsync(); } catch (IOException) { } output = null; }
                    retry = DateTime.UtcNow.AddSeconds(30);
                }
            }
        }
        finally { if (output is not null) await output.DisposeAsync(); }
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true;
        // Usually EOF after Job cleanup; cancellation also bounds inherited-output-handle faults.
        if (await Task.WhenAny(reader, Task.Delay(1000)) != reader) lifetime.Cancel();
        await reader; await writer; lifetime.Dispose();
    }
}
public sealed class IncrementalLogDecoder
{
    private readonly Decoder decoder;
    public IncrementalLogDecoder(int codePage) { Encoding.RegisterProvider(CodePagesEncodingProvider.Instance); decoder = Encoding.GetEncoding(codePage).GetDecoder(); }
    public string Decode(ReadOnlySpan<byte> bytes, bool flush = false)
    {
        var chars = new char[bytes.Length * 2 + 8]; decoder.Convert(bytes, chars, flush, out _, out var used, out _);
        return new string(chars, 0, used);
    }
}
