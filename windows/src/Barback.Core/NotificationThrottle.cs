namespace Barback.Core;

/// <summary>Decides which attention events become toast notifications (interaction design §7).</summary>
public sealed class NotificationThrottle(Func<DateTimeOffset>? now = null, TimeSpan? window = null)
{
    public static readonly TimeSpan DefaultWindow = TimeSpan.FromMinutes(10);
    private readonly Func<DateTimeOffset> clock = now ?? (() => DateTimeOffset.UtcNow);
    private readonly TimeSpan span = window ?? DefaultWindow;
    private readonly Dictionary<string, DateTimeOffset> sent = [];
    /// <summary>
    /// Fatal repeats per program are collapsed; log-loss and interrupted-session reports are collapsed globally (one toast
    /// however many programs are affected). Failed or timed-out commands and unconfirmed cleanup always notify.
    /// </summary>
    public bool ShouldNotify(EventRecord e)
    {
        string? key = e.Type switch
        {
            "Fatal" => $"{e.ProgramId}:Fatal",
            "LogIncomplete" or "AppInterrupted" => e.Type,
            _ => null
        };
        if (key is null) return true;
        lock (sent)
        {
            var at = clock();
            if (sent.TryGetValue(key, out var previous) && at - previous < span) return false;
            sent[key] = at; return true;
        }
    }
}
