namespace Barback.Core;
/// <summary>Shared reservation counters; disk reads are performed only at initialization or explicit maintenance.</summary>
public sealed class LogQuota(long limit, long initialBytes = 0)
{
    private long used = initialBytes;
    public long UsedBytes => Interlocked.Read(ref used);
    public bool TryReserve(long bytes)
    {
        while (true) { var before = Interlocked.Read(ref used); if (bytes > limit - before) return false; if (Interlocked.CompareExchange(ref used, before + bytes, before) == before) return true; }
    }
    public void Release(long bytes) { Interlocked.Add(ref used, -bytes); }
}
