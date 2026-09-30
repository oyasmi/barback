using System.Text;
namespace Barback.Core;

public sealed record FieldError(string Field, string Message, int? Line = null);
public static class ConfigurationValidator
{
    public static IReadOnlyList<FieldError> Validate(ProgramConfig c, bool forLaunch = true)
    {
        var errors = new List<FieldError>();
        void Check(bool ok, string field, string message) { if (!ok) errors.Add(new(field, message)); }
        Check(!string.IsNullOrWhiteSpace(c.Name) && c.Name.Length <= 200, "Name", "Name must contain 1–200 characters.");
        Check(!c.Name.Contains('\0') && !c.Group.Contains('\0') && !c.Notes.Contains('\0'), "Name", "NUL is not allowed.");
        var l = c.Launch; var p = c.Policy;
        Check(l.Arguments.All(x => !x.Contains('\0')), "Arguments", "NUL is not allowed.");
        Check(l.RawArguments is null || l.Arguments.Length == 0, "Arguments", "Choose arguments or raw arguments.");
        Check(l.RawArguments?.Contains('\0') != true && !l.ScriptText.Contains('\0'), "Arguments", "NUL is not allowed.");
        Check(double.IsFinite(l.StopWaitSeconds) && l.StopWaitSeconds >= 0 && l.StopWaitSeconds <= 300, "StopWaitSeconds", "Use 0–300 seconds.");
        Check(double.IsFinite(p.StartSeconds) && p.StartSeconds >= 0 && p.StartSeconds <= 3600, "StartSeconds", "Use 0–3600 seconds.");
        Check(p.StartRetries is >= 0 and <= 100, "StartRetries", "Use 0–100 retries.");
        Check(double.IsFinite(p.TimeoutSeconds) && p.TimeoutSeconds >= 0, "Timeout", "Timeout must be non-negative.");
        Check(double.IsFinite(p.BackoffBaseSeconds) && p.BackoffBaseSeconds > 0 && double.IsFinite(p.BackoffMaxSeconds) && p.BackoffMaxSeconds >= p.BackoffBaseSeconds, "Backoff", "Invalid backoff range.");
        Check(p.StormLimit > 0 && double.IsFinite(p.StormWindowSeconds) && p.StormWindowSeconds > 0, "Storm", "Invalid storm limits.");
        Check(p.ExpectedCodes.Length > 0 && p.HistoryLimit is >= 1 and <= 10000, "History", "Invalid exit codes or history limit.");
        Check(l.LogSegmentBytes is >= 65536 and <= 1073741824 && l.LogSegments is >= 0 and <= 100, "Logs", "Invalid log budget.");
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        try { _ = Encoding.GetEncoding(l.EncodingCodePage); } catch (ArgumentException) { errors.Add(new("Encoding", "Unsupported encoding.")); }
        var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var e in l.Environment)
        {
            Check(e.Key.Length > 0 && !e.Key.Contains('=') && !e.Key.Contains('\0'), "Environment", "Invalid variable name.");
            Check(keys.Add(e.Key), "Environment", "Duplicate variable name (case insensitive).");
            Check(!(forLaunch || c.Enabled) || !e.NeedsInput, "Environment", "Sensitive value requires re-entry for this Windows account.");
            Check(e.Value?.Contains('\0') != true, "Environment", "NUL is not allowed.");
        }
        if (forLaunch || c.Enabled)
        {
            Check(Path.IsPathFullyQualified(l.WorkingDirectory) && Directory.Exists(l.WorkingDirectory), "WorkingDirectory", "Choose an existing absolute directory.");
            if (l.Mode != ExecutionMode.Cmd)
                Check(Path.IsPathFullyQualified(l.Executable) && File.Exists(l.Executable) && l.Executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase), "Executable", "Choose an existing absolute .exe path.");
            if (l.Mode == ExecutionMode.PowerShellFile) Check(Path.IsPathFullyQualified(l.ScriptPath) && File.Exists(l.ScriptPath), "ScriptPath", "Choose an existing absolute script path.");
            if (l.Mode is ExecutionMode.PowerShellText or ExecutionMode.Cmd) Check(!string.IsNullOrWhiteSpace(l.ScriptText), "ScriptText", "Enter explicit shell command text.");
            if (l.Mode == ExecutionMode.Cmd) Check(!l.WorkingDirectory.StartsWith(@"\\", StringComparison.Ordinal), "WorkingDirectory", "cmd requires a local working directory.");
        }
        return errors;
    }
}
public static class EnvironmentDraft
{
    // Parse only on save. The editor retains its own exact, unmodified text.
    public static (EnvironmentEntry[] Entries, FieldError[] Errors) Parse(string raw)
    {
        var entries = new List<EnvironmentEntry>(); var errors = new List<FieldError>();
        var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var lines = raw.Replace("\r\n", "\n").Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i]; if (string.IsNullOrWhiteSpace(line)) continue;
            var eq = line.IndexOf('='); var remove = line.StartsWith('-') && eq < 0;
            var secret = line.StartsWith('!');
            var key = remove ? line[1..] : eq > 0 ? line[(secret ? 1 : 0)..eq] : "";
            if (key.Length == 0 || key.Contains('\0') || key.Contains('=') || !keys.Add(key))
            { errors.Add(new("Environment", "Invalid or duplicate variable name.", i + 1)); continue; }
            var value = remove ? null : line[(eq + 1)..];
            if (value?.Contains('\0') == true) { errors.Add(new("Environment", "NUL is not allowed.", i + 1)); continue; }
            entries.Add(new(key, value, secret, remove));
        }
        return (entries.ToArray(), errors.ToArray());
    }
    public static Dictionary<string, string> Merge(IEnumerable<KeyValuePair<string, string>> baseline, params IEnumerable<EnvironmentEntry>[] layers)
    {
        var result = new Dictionary<string, string>(baseline, StringComparer.OrdinalIgnoreCase);
        foreach (var layer in layers) foreach (var e in layer) { if (e.Remove) result.Remove(e.Key); else result[e.Key] = e.Value ?? ""; }
        return result;
    }
}
public static class WindowsCommandLine
{
    public static string Quote(string argument)
    {
        if (argument.Length > 0 && !argument.Any(c => char.IsWhiteSpace(c) || c == '"')) return argument;
        var b = new StringBuilder("\""); int slashes = 0;
        foreach (var ch in argument)
        {
            if (ch == '\\') { slashes++; continue; }
            if (ch == '"') b.Append('\\', slashes * 2 + 1).Append('"');
            else b.Append('\\', slashes).Append(ch);
            slashes = 0;
        }
        return b.Append('\\', slashes * 2).Append('"').ToString();
    }
    public static (string Executable, string CommandLine) Build(LaunchSpec s, string systemDirectory)
    {
        var exe = s.Mode == ExecutionMode.Cmd ? Path.Combine(systemDirectory, "cmd.exe") : s.Executable;
        string args = s.Mode switch
        {
            ExecutionMode.Cmd => "/d /s /c \"" + s.ScriptText + "\"",
            ExecutionMode.PowerShellText => "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(s.ScriptText)),
            ExecutionMode.PowerShellFile => "-NoLogo -NoProfile -NonInteractive -File " + Quote(s.ScriptPath) + " " + string.Join(" ", s.Arguments.Select(Quote)),
            _ => s.RawArguments ?? string.Join(" ", s.Arguments.Select(Quote))
        };
        var command = Quote(exe) + " " + args;
        if (command.Length >= 32767 || command.Contains('\0')) throw new ArgumentException("Command line exceeds Windows limits.");
        return (exe, command);
    }
}
