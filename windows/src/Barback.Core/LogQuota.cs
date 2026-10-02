namespace Barback.Core;
/// <summary>Shared reservation counters; disk reads are performed only at initialization or explicit maintenance.</summary>
public sealed class LogQuota(long limit, long initialBytes = 0, Func<long>? tickSource = null)
{
    /// <summary>Minimum spacing between <see cref="Pressure"/> notifications.</summary>
    public const long PressureIntervalMilliseconds = 30_000;
    private long used = initialBytes;
    private long lastPressure = long.MinValue;
    private readonly Func<long> tick = tickSource ?? (() => Environment.TickCount64);
    public long Limit { get; } = limit;
    public long UsedBytes => Interlocked.Read(ref used);
    /// <summary>Raised (debounced, on the caller's thread) when a reservation is refused because the budget is exhausted.</summary>
    public event Action? Pressure;
    public bool TryReserve(long bytes, bool reportPressure = true)
    {
        while (true)
        {
            var before = Interlocked.Read(ref used);
            if (bytes > Limit - before) { if (reportPressure) ReportPressure(); return false; }
            if (Interlocked.CompareExchange(ref used, before + bytes, before) == before) return true;
        }
    }
    public void Release(long bytes) { Interlocked.Add(ref used, -bytes); }
    public void ReportPressure()
    {
        var now = tick(); var last = Interlocked.Read(ref lastPressure);
        if (last != long.MinValue && now - last < PressureIntervalMilliseconds) return;
        if (Interlocked.CompareExchange(ref lastPressure, now, last) != last) return; // another thread announced it
        try { Pressure?.Invoke(); } catch { /* a faulty subscriber must not break log capture */ }
    }
}
