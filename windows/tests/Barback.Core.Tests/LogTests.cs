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
}
