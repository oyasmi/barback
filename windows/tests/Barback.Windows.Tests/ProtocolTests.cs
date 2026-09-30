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
}
