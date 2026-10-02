using System.Text;
namespace Barback.Core;

public enum AppLogLevel { Info, Warning, Error }

/// <summary>
/// Barback's own diagnostic log. Writes never throw and never block callers on I/O failures, so it is safe in any error path.
/// Callers must not pass secrets, environment values, arguments, script text or program output; programs are identified by Id.
/// </summary>
public sealed class AppLog(string directory, long maxBytes = 5L * 1024 * 1024, int files = 3, string fileName = "barback.log")
{
    private readonly object gate = new();
    private string Path(int generation) => System.IO.Path.Combine(directory, generation == 0 ? fileName : fileName + "." + generation);
    public string Directory => directory;
    public string FileName => fileName;

    public void Write(AppLogLevel level, string category, string message, Exception? exception = null)
    {
        try
        {
            var text = Format(DateTimeOffset.UtcNow, level, category, message, exception);
            lock (gate)
            {
                System.IO.Directory.CreateDirectory(directory);
                RotateIfNeeded(Encoding.UTF8.GetByteCount(text));
                // Shared read/delete so diagnostics export and users can open the file while the app keeps logging.
                using var stream = new FileStream(Path(0), FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                stream.Write(Encoding.UTF8.GetBytes(text));
            }
        }
        catch { /* logging must never become the failure */ }
    }
    public void Info(string category, string message) => Write(AppLogLevel.Info, category, message);
    public void Warning(string category, string message, Exception? exception = null) => Write(AppLogLevel.Warning, category, message, exception);
    public void Error(string category, string message, Exception? exception = null) => Write(AppLogLevel.Error, category, message, exception);

    private void RotateIfNeeded(int incoming)
    {
        var current = new FileInfo(Path(0));
        if (!current.Exists || current.Length + incoming <= maxBytes) return;
        if (files <= 1) { current.Delete(); return; }
        var oldest = Path(files - 1); if (File.Exists(oldest)) File.Delete(oldest);
        for (int generation = files - 2; generation >= 1; generation--) if (File.Exists(Path(generation))) File.Move(Path(generation), Path(generation + 1), true);
        File.Move(Path(0), Path(1), true);
    }
    internal static string Format(DateTimeOffset at, AppLogLevel level, string category, string message, Exception? exception)
    {
        var sb = new StringBuilder();
        sb.Append(at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")).Append("  ").Append(level.ToString().ToUpperInvariant().PadRight(7)).Append("  ").Append(OneLine(category)).Append("  ").Append(OneLine(message));
        if (exception is not null) sb.Append("  [").Append(exception.GetType().Name).Append(": ").Append(OneLine(exception.Message)).Append(']');
        sb.Append('\n');
        for (var inner = exception; inner is not null; inner = inner.InnerException)
        {
            if (inner != exception) sb.Append("    caused by ").Append(inner.GetType().Name).Append(": ").Append(OneLine(inner.Message)).Append('\n');
            foreach (var line in (inner.StackTrace ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries)) sb.Append("    ").Append(line.TrimEnd('\r').TrimStart()).Append('\n');
        }
        return sb.ToString();
    }
    private static string OneLine(string text) => text.Replace("\r\n", " ").Replace('\n', ' ').Replace('\r', ' ');
}
