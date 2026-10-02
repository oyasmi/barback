using System.Buffers.Binary;
using Barback.Windows;
namespace Barback.Windows.Tests;

public class ProtocolTests
{
    [Fact]
    public async Task RejectsOversizedLengthBeforeAllocatingPayload()
    {
        var bytes = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(bytes, HostProtocol.MaxBytes + 1);
        await Assert.ThrowsAsync<InvalidDataException>(() => new HostProtocol(new MemoryStream(bytes)).ReadAsync(CancellationToken.None));
    }
    [Fact]
    public async Task RejectsOldProtocolVersion()
    {
        using var stream = new MemoryStream(); var protocol = new HostProtocol(stream); await protocol.SendAsync(new("Break", Version: 99), CancellationToken.None); stream.Position = 0;
        await Assert.ThrowsAsync<InvalidDataException>(() => protocol.ReadAsync(CancellationToken.None));
    }
    [Theory] // F5
    [InlineData(-7_200_000, true)]  // created two hours before this boot: the PID cannot belong to this boot's process
    [InlineData(-30_000, false)]    // 30 s before the computed boot time: inside the clock tolerance
    [InlineData(5_000, false)]      // created after boot
    public void BootTimeFilterRejectsProcessesFromBeforeBoot(long createdMsRelativeToBoot, bool predates)
    {
        // FILETIME ticks are 100 ns; any large epoch keeps the arithmetic positive.
        const long boot = 1_000_000_000_000_000, uptimeMs = 3_600_000;
        long now = boot + uptimeMs * 10_000, created = boot + createdMsRelativeToBoot * 10_000;
        Assert.Equal(predates, WindowsProcessHost.PredatesBoot(created, now, uptimeMs));
    }
}
