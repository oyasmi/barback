namespace Barback.Core;

public sealed record ImportIssue(int Line, string Field, string Status, string Reason);
public sealed record ImportDraft(ProgramConfig Config, string OriginalCommand, ImportIssue[] Issues);
public static class SupervisorImporter
{
    private static readonly HashSet<string> Supported = ["command", "directory", "priority", "autostart", "autorestart", "exitcodes", "startsecs", "startretries", "environment", "stdout_logfile", "stderr_logfile", "stdout_logfile_maxbytes", "stdout_logfile_backups", "stopsignal", "stopasgroup", "killasgroup"];
    public static IReadOnlyList<ImportDraft> Preview(string text)
    {
        if (text.Length > 1024 * 1024) throw new ArgumentException("Import exceeds 1 MiB.");
        var drafts = new List<ImportDraft>(); var fields = new Dictionary<string, (string Value, int Line)>(StringComparer.OrdinalIgnoreCase);
        var issues = new List<ImportIssue>(); string? name = null; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Finish()
        {
            if (name is null) return;
            string Get(string key, string fallback = "") => fields.GetValueOrDefault(key).Value ?? fallback;
            int Number(string key, int fallback) { if (!fields.ContainsKey(key)) return fallback; if (int.TryParse(Get(key), out var n) && n >= 0) return n; issues.Add(new(fields[key].Line, key, "NeedsRepair", "Invalid number.")); return fallback; }
            var restart = Get("autorestart", "unexpected") switch { "false" => RestartPolicy.Never, "true" => RestartPolicy.Always, _ => RestartPolicy.Unexpected };
            var codes = new List<uint>(); foreach (var raw in Get("exitcodes", "0").Split(',')) if (uint.TryParse(raw.Trim(), out var code)) codes.Add(code); else issues.Add(new(fields.GetValueOrDefault("exitcodes").Line, "exitcodes", "NeedsRepair", "Invalid DWORD exit code."));
            issues.Add(new(fields.GetValueOrDefault("command").Line, "command", "NeedsRepair", "Select explicit Windows execution mode and executable; no command translation."));
            issues.Add(new(0, "autostart", "Mapped", "Imported drafts are disabled; autostart is always false."));
            if (!seen.Add(name.Normalize().ToUpperInvariant())) issues.Add(new(0, "name", "NeedsRepair", "Duplicate name; rename or skip."));
            drafts.Add(new(new()
            {
                Name = name,
                Notes = "Imported command (needs Windows repair): " + Get("command"),
                Enabled = false,
                Launch = new() { WorkingDirectory = Get("directory") },
                Priority = Number("priority", 999),
                Policy = new() { Autostart = false, StartSeconds = Number("startsecs", 1), StartRetries = Number("startretries", 3), Restart = restart, ExpectedCodes = codes.Count == 0 ? [0] : codes.ToArray() }
            }, Get("command"), issues.ToArray()));
        }
        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim(); if (line.Length == 0 || line.StartsWith(';') || line.StartsWith('#')) continue;
            if (line.StartsWith('[') && line.EndsWith(']')) { Finish(); fields.Clear(); issues.Clear(); name = line.StartsWith("[program:", StringComparison.OrdinalIgnoreCase) ? line[9..^1] : null; continue; }
            if (name is null) continue;
            var eq = line.IndexOf('='); if (eq <= 0) { issues.Add(new(i + 1, "line", "Unsupported", "Expected key=value.")); continue; }
            var key = line[..eq].Trim(); var value = line[(eq + 1)..].Trim();
            if (!fields.TryAdd(key, (value, i + 1))) issues.Add(new(i + 1, key, "NeedsRepair", "Duplicate field."));
            if (!Supported.Contains(key) || value.Contains("%(")) issues.Add(new(i + 1, key, "Unsupported", "Unsupported field or interpolation; no expansion or includes are performed."));
            else if (key is "environment" or "directory" or "stopsignal" or "stopasgroup" or "killasgroup" || key.Contains("logfile")) issues.Add(new(i + 1, key, "NeedsRepair", "Review Windows paths, environment, logging or stop semantics."));
        }
        Finish(); return drafts;
    }
}
