using System.Text;
namespace Barback.Core;

/// <summary>Lines added and evicted by one operation. Apply as: remove <see cref="RemovedFromStart"/> lines from the front, then append <see cref="Added"/>.</summary>
public sealed record LogBufferDelta(IReadOnlyList<string> Added, int RemovedFromStart, string? Partial);

/// <summary>
/// Bounded, terminal-style line store behind the log viewer. Input is decoded text; the raw file bytes are never touched.
/// A lone CR rewinds the unfinished line (progress bars); ANSI escape sequences and C0 controls are stripped from finished
/// lines. The unfinished line keeps its raw text, so an escape sequence split across two reads is still recognised.
/// </summary>
public sealed class LogLineBuffer(int maxLines = LogLineBuffer.DefaultMaxLines, int maxChars = LogLineBuffer.DefaultMaxChars)
{
    public const int DefaultMaxLines = 10_000, DefaultMaxChars = 8 * 1024 * 1024, MaxLineChars = 64 * 1024;
    private readonly List<string> lines = [];
    private readonly StringBuilder pending = new();
    private bool carriageReturn;
    private long chars;
    public IReadOnlyList<string> Lines => lines;
    public int Count => lines.Count;
    /// <summary>Monotonic counters so a view can reconcile itself after any number of operations.</summary>
    public long TotalAdded { get; private set; }
    public long TotalRemoved { get; private set; }
    /// <summary>The unfinished last line as it should be displayed, or null when there is none.</summary>
    public string? Partial { get { var text = Clean(pending.ToString()); return text.Length == 0 ? null : text; } }

    public LogBufferDelta Append(string decoded)
    {
        var added = new List<string>(); int before = lines.Count;
        foreach (var c in decoded)
        {
            if (carriageReturn)
            {
                carriageReturn = false;
                if (c == '\n') { Complete(added); continue; }
                pending.Clear(); // CR not followed by LF: the new text overwrites the line
            }
            if (c == '\n') Complete(added);
            else if (c == '\r') carriageReturn = true;
            else { pending.Append(c); if (pending.Length >= MaxLineChars) CompleteChunk(added); }
        }
        return Finish(added, before);
    }
    /// <summary>Turns the unfinished line into a finished one (end of a run, before a marker).</summary>
    public LogBufferDelta Flush()
    {
        var added = new List<string>(); int before = lines.Count;
        carriageReturn = false;
        if (pending.Length > 0) Complete(added);
        return Finish(added, before);
    }
    /// <summary>Finishes any unfinished line, then adds <paramref name="text"/> verbatim as its own line.</summary>
    public LogBufferDelta AppendMarker(string text)
    {
        var added = new List<string>(); int before = lines.Count;
        carriageReturn = false;
        if (pending.Length > 0) Complete(added);
        added.Add(text);
        return Finish(added, before);
    }
    public void Clear() { lines.Clear(); pending.Clear(); carriageReturn = false; chars = 0; TotalRemoved = TotalAdded; }

    private void Complete(List<string> added) { added.Add(Clean(pending.ToString())); pending.Clear(); }
    private void CompleteChunk(List<string> added)
    {
        int take = pending.Length;
        if (take > 1 && char.IsHighSurrogate(pending[take - 1])) take--; // never split a surrogate pair
        added.Add(Clean(pending.ToString(0, take))); pending.Remove(0, take);
    }
    private LogBufferDelta Finish(List<string> added, int before)
    {
        lines.AddRange(added); foreach (var line in added) chars += line.Length; TotalAdded += added.Count;
        int evict = 0;
        if (lines.Count > maxLines || chars > maxChars)
        {
            // Evict in blocks of at least 10 % so a steady stream does not touch the view on every refresh.
            int keepLines = maxLines - Math.Max(1, maxLines / 10); long keepChars = maxChars - Math.Max(1, maxChars / 10); long remaining = chars;
            while (evict < lines.Count && (lines.Count - evict > keepLines || remaining > keepChars)) remaining -= lines[evict++].Length;
            lines.RemoveRange(0, evict); chars = remaining; TotalRemoved += evict;
        }
        int removedPrior = Math.Min(evict, before), removedNew = evict - removedPrior;
        return new(removedNew == 0 ? added : added.Skip(removedNew).ToArray(), removedPrior, Partial);
    }

    /// <summary>Strips CSI/OSC/two-byte escape sequences and C0 controls other than tab.</summary>
    public static string Clean(string text)
    {
        bool needs = false;
        foreach (var c in text) if (c < ' ' && c != '\t') { needs = true; break; }
        if (!needs) return text;
        var sb = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length;)
        {
            var c = text[i];
            if (c == '\u001b') i = SkipEscape(text, i);
            else if (c < ' ' && c != '\t') i++;
            else { sb.Append(c); i++; }
        }
        return sb.ToString();
    }
    /// <returns>Index just past the escape sequence starting at <paramref name="start"/>; an unterminated sequence consumes the rest.</returns>
    private static int SkipEscape(string s, int start)
    {
        int i = start + 1; if (i >= s.Length) return s.Length;
        switch (s[i])
        {
            case '[':
                i++; while (i < s.Length && s[i] is >= ' ' and <= '?') i++;
                return i < s.Length && s[i] is >= '@' and <= '~' ? i + 1 : i;
            case ']' or 'P' or 'X' or '^' or '_': // OSC and other string sequences end with BEL or ST (ESC \)
                for (i++; i < s.Length; i++)
                {
                    if (s[i] == '\a') return i + 1;
                    if (s[i] == '\u001b') return i + 1 < s.Length && s[i + 1] == '\\' ? i + 2 : i;
                }
                return s.Length;
            case >= ' ' and <= '/': // ESC ( B and similar: intermediates then one final byte
                while (i < s.Length && s[i] is >= ' ' and <= '/') i++;
                return i < s.Length && s[i] is >= '0' and <= '~' ? i + 1 : i;
            case < ' ': return i; // ESC followed by a control character: drop only the ESC
            default: return i + 1;
        }
    }
}
