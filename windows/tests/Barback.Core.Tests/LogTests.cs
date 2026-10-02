using Barback.Core;
namespace Barback.Core.Tests;

public class LogTests
{
    [Fact]
    public async Task RotationKeepsBoundedSegmentsWithoutChangingRawBytes()
    {
        var root = Path.Combine(Path.GetTempPath(), "barback-log-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            var data = Enumerable.Repeat((byte)0xFE, 4 * 16384).ToArray(); var file = Path.Combine(root, "stdout.log");
            await using (var collector = new LogCollector(new MemoryStream(data), file, 16384, 2, _ => { })) { }
            Assert.Equal(3, Directory.GetFiles(root, "*.log*").Length);
            foreach (var path in Directory.GetFiles(root, "*.log*")) { Assert.Equal(16384, new FileInfo(path).Length); Assert.All(await File.ReadAllBytesAsync(path), b => Assert.Equal(0xFE, b)); }
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task QuotaRejectsAdditionalBytesAndRetainsRawEvidence()
    {
        var root = Path.Combine(Path.GetTempPath(), "barback-quota-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            var quota = new LogQuota(16384); var file = Path.Combine(root, "stdout.log"); var collector = new LogCollector(new MemoryStream(new byte[65536]), file, 65536, 1, _ => { }, quota);
            await collector.DisposeAsync(); Assert.Equal(16384, new FileInfo(file).Length); Assert.Equal(16384, quota.UsedBytes); Assert.Equal(49152, collector.DroppedBytes);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public async Task LargeOutputIsDrainedWithBoundedQueueAndVisibleLoss()
    {
        var root = Path.Combine(Path.GetTempPath(), "barback-log-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            bool signaled = false; var collector = new LogCollector(new MemoryStream(new byte[8 * 1024 * 1024]), Path.Combine(root, "stdout.log"), 1024 * 1024, 1, _ => signaled = true);
            await collector.DisposeAsync(); Assert.True(collector.DroppedBytes > 0); Assert.True(signaled);
        }
        finally { Directory.Delete(root, true); }
    }
    private static string TempDir() { var root = Path.Combine(Path.GetTempPath(), "barback-log-" + Guid.NewGuid()); Directory.CreateDirectory(root); return root; }
    [Fact] // F7
    public async Task ServiceWithoutRunLimitKeepsRotatingPastFiftyMiBAndNeverStopsWriting()
    {
        var root = TempDir();
        try
        {
            // 1 MiB segments x 2 kept, 60 MiB of data: far beyond the old per-run 50 MiB cap.
            var file = Path.Combine(root, "stdout.log"); var data = new byte[60 * 1024 * 1024]; for (int i = 0; i < data.Length; i += 1024 * 1024) Array.Fill(data, (byte)(i / (1024 * 1024) + 1), i, 1024 * 1024);
            var input = new ThrottledStream(data); var collector = new LogCollector(input, file, 1024 * 1024, 2, _ => { }, new LogQuota(1024L * 1024 * 1024));
            await WaitAsync(() => input.Eof, 30); await collector.DisposeAsync();
            Assert.Equal(3, Directory.GetFiles(root, "stdout.log*").Where(f => !f.EndsWith(".gaps")).Count());
            Assert.Equal(0, collector.DroppedBytes);
            Assert.Equal((byte)60, (await File.ReadAllBytesAsync(file))[^1]); // newest bytes are on disk
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact] // F7
    public async Task OneShotRunLimitTruncatesOnceAndMarksGaps()
    {
        var root = TempDir();
        try
        {
            var file = Path.Combine(root, "stdout.log"); var run = new LogQuota(32768);
            var input = new ThrottledStream(new byte[65536]); var collector = new LogCollector(input, file, 1024 * 1024, 3, _ => { }, new LogQuota(1024L * 1024 * 1024), run);
            await WaitAsync(() => input.Eof); await collector.DisposeAsync();
            Assert.Equal(32768, new FileInfo(file).Length); Assert.Equal(32768, collector.DroppedBytes);
            var gaps = (await File.ReadAllLinesAsync(file + ".gaps")); Assert.Single(gaps); Assert.Contains("run-output-limit reached at 32768", gaps[0]);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact] // F7 / F8
    public async Task GlobalLimitWithNothingToRotateDropsRaisesPressureAndRecoversAfterRelease()
    {
        var root = TempDir();
        try
        {
            long now = 0; var global = new LogQuota(16384, tickSource: () => now); int pressure = 0; global.Pressure += () => pressure++;
            var file = Path.Combine(root, "stdout.log"); var input = new GatedStream();
            var collector = new LogCollector(input, file, 1024 * 1024, 1, _ => { }, global);
            await input.PushAsync(new byte[16384]); await input.PushAsync(new byte[16384]); // second chunk exceeds the budget
            await WaitAsync(() => collector.DroppedBytes == 16384);
            Assert.Equal(1, pressure);
            global.Release(16384); await input.PushAsync(new byte[16384]); // maintenance freed room: capture resumes
            input.Complete(); await collector.DisposeAsync();
            Assert.Equal(32768, new FileInfo(file).Length); Assert.Equal(16384, collector.DroppedBytes);
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact] // F8
    public void PressureIsDebouncedWithinThirtySeconds()
    {
        long now = 1000; var quota = new LogQuota(10, tickSource: () => now); int count = 0; quota.Pressure += () => count++;
        for (int i = 0; i < 5; i++) Assert.False(quota.TryReserve(11));
        Assert.Equal(1, count);
        now += LogQuota.PressureIntervalMilliseconds - 1; quota.ReportPressure(); Assert.Equal(1, count);
        now += 1; quota.ReportPressure(); Assert.Equal(2, count);
        Assert.True(quota.TryReserve(10, reportPressure: false)); Assert.False(quota.TryReserve(1, reportPressure: false)); Assert.Equal(2, count);
    }
    [Theory] // F7
    [InlineData(65536L, 0, true)]
    [InlineData(65535L, 0, false)]
    [InlineData(256L * 1024 * 1024, 0, true)]
    [InlineData(256L * 1024 * 1024 + 1, 0, false)]
    [InlineData(10L * 1024 * 1024, 20, true)]
    [InlineData(10L * 1024 * 1024, 21, false)]
    [InlineData(25L * 1024 * 1024, 9, true)]   // 2 x 25 MiB x 10 = 500 MiB
    [InlineData(26L * 1024 * 1024, 9, false)]  // 520 MiB: over the per-program budget
    public void LogBudgetBoundaries(long segmentBytes, int segments, bool valid)
    {
        var errors = ConfigurationValidator.Validate(new ProgramConfig { Name = "x", Enabled = false, Launch = new() { LogSegmentBytes = segmentBytes, LogSegments = segments } }, false);
        Assert.Equal(valid, errors.All(e => e.Field != "Logs"));
    }
    private static async Task WaitAsync(Func<bool> condition, int seconds = 5) { var end = DateTime.UtcNow.AddSeconds(seconds); while (!condition()) { if (DateTime.UtcNow > end) throw new TimeoutException(); await Task.Delay(10); } }
    /// <summary>Delivers a buffer in 16 KiB reads and lets the test decide when each chunk arrives.</summary>
    private sealed class GatedStream : Stream
    {
        private readonly System.Threading.Channels.Channel<byte[]> chunks = System.Threading.Channels.Channel.CreateUnbounded<byte[]>();
        private byte[] current = []; private int offset;
        public async Task PushAsync(byte[] data) { await chunks.Writer.WriteAsync(data); await Task.Delay(100); }
        public void Complete() => chunks.Writer.TryComplete();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            if (offset >= current.Length) { if (!await chunks.Reader.WaitToReadAsync(token)) return 0; current = await chunks.Reader.ReadAsync(token); offset = 0; }
            var n = Math.Min(buffer.Length, current.Length - offset); current.AsMemory(offset, n).CopyTo(buffer); offset += n; return n;
        }
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false; public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { } public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
    /// <summary>MemoryStream that yields at every read so the single-reader/single-writer pipeline never overflows its bounded queue.</summary>
    private sealed class ThrottledStream(byte[] data) : Stream
    {
        private int position, reads;
        public bool Eof { get; private set; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            if (position >= data.Length) { Eof = true; return 0; }
            if (++reads % 2 == 0) await Task.Delay(1, token); else await Task.Yield();
            var n = Math.Min(buffer.Length, data.Length - position); data.AsMemory(position, n).CopyTo(buffer); position += n; return n;
        }
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false; public override long Length => data.Length; public override long Position { get => position; set => throw new NotSupportedException(); }
        public override void Flush() { } public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
