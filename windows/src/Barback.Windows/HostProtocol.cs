using System.Buffers.Binary;
using System.Text.Json;
using Barback.Core;
namespace Barback.Windows;

public sealed record HostMessage(string Type, int Version = 1, LaunchSpec? Launch = null, Dictionary<string, string>? Environment = null, int? Pid = null, long? CreationTime = null, uint? ExitCode = null);
public sealed class HostProtocol(Stream stream)
{
    public const int MaxBytes = 1024 * 1024;
    private readonly SemaphoreSlim writes = new(1);
    public async Task SendAsync(HostMessage message, CancellationToken token)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(message); if (bytes.Length > MaxBytes) throw new InvalidDataException("Host message too long.");
        var prefix = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(prefix, bytes.Length);
        await writes.WaitAsync(token); try { await stream.WriteAsync(prefix, token); await stream.WriteAsync(bytes, token); await stream.FlushAsync(token); } finally { writes.Release(); }
    }
    public async Task<HostMessage> ReadAsync(CancellationToken token)
    {
        var prefix = new byte[4]; await stream.ReadExactlyAsync(prefix, token); var length = BinaryPrimitives.ReadInt32LittleEndian(prefix);
        if (length <= 0 || length > MaxBytes) throw new InvalidDataException("Invalid host message length.");
        var data = new byte[length]; await stream.ReadExactlyAsync(data, token); var message = JsonSerializer.Deserialize<HostMessage>(data) ?? throw new InvalidDataException("Invalid host message.");
        if (message.Version != 1) throw new InvalidDataException("Unsupported host protocol version."); return message;
    }
}
