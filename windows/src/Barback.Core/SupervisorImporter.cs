namespace Barback.Core;

public sealed record ImportIssue(int Line, string Field, string Status, string Reason);
public sealed record ImportDraft(ProgramConfig Config, string OriginalCommand, ImportIssue[] Issues);
public static class SupervisorImporter
{
    private static readonly HashSet<string> Supported = ["command", "directory", "priority", "autostart", "autorestart", "exitcodes", "startsecs", "startretries", "environment", "stdout_logfile", "stderr_logfile", "stdout_logfile_maxbytes", "stdout_logfile_backups", "stopwaitsecs", "stopsignal", "stopasgroup", "killasgroup"];
    /// <summary>Supervisor treats a ';' preceded by whitespace as the start of a comment.</summary>
    private static string StripInlineComment(string value)
    {
        for (int i = 1; i < value.Length; i++) if (value[i] == ';' && char.IsWhiteSpace(value[i - 1])) return value[..i].TrimEnd();
        return value;
    }
    private static bool TryParseBytes(string text, out long bytes)
    {
        bytes = 0; var match = System.Text.RegularExpressions.Regex.Match(text.Trim(), @"^(\d+)\s*(KB|MB|GB)?$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        if (!match.Success || !long.TryParse(match.Groups[1].Value, out var number)) return false;
        long unit = match.Groups[2].Value.ToUpperInvariant() switch { "KB" => 1024, "MB" => 1024 * 1024, "GB" => 1024L * 1024 * 1024, _ => 1 };
        try { bytes = checked(number * unit); return true; } catch (OverflowException) { return false; }
    }
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
            // Supervisor accepts several boolean spellings in any case.
            var restartText = Get("autorestart", "unexpected").Trim().ToLowerInvariant();
            var restart = restartText switch { "false" or "f" or "no" or "n" or "off" or "0" => RestartPolicy.Never, "true" or "t" or "yes" or "y" or "on" or "1" => RestartPolicy.Always, _ => RestartPolicy.Unexpected };
            if (fields.ContainsKey("autorestart") && restartText is not ("unexpected" or "false" or "f" or "no" or "n" or "off" or "0" or "true" or "t" or "yes" or "y" or "on" or "1"))
                issues.Add(new(fields["autorestart"].Line, "autorestart", "NeedsRepair", "Unknown autorestart value; 'unexpected' assumed."));
            var defaults = new LaunchSpec(); long segmentBytes = defaults.LogSegmentBytes; int segments = defaults.LogSegments; double stopWait = defaults.StopWaitSeconds;
            if (fields.TryGetValue("stdout_logfile_maxbytes", out var maxBytes))
            {
                if (TryParseBytes(maxBytes.Value, out var bytes) && bytes is >= ConfigurationValidator.MinLogSegmentBytes and <= ConfigurationValidator.MaxLogSegmentBytes) { segmentBytes = bytes; issues.Add(new(maxBytes.Line, "stdout_logfile_maxbytes", "Mapped", "Mapped to the log segment size (applies to stdout and stderr).")); }
                else issues.Add(new(maxBytes.Line, "stdout_logfile_maxbytes", "NeedsRepair", "Segment size must be 64 KiB–256 MiB (unlimited is not supported); the default is kept."));
            }
            if (fields.TryGetValue("stdout_logfile_backups", out var backups))
            {
                if (int.TryParse(backups.Value, out var count) && count is >= 0 and <= ConfigurationValidator.MaxLogSegments) { segments = count; issues.Add(new(backups.Line, "stdout_logfile_backups", "Mapped", "Mapped to the number of rotated log segments.")); }
                else issues.Add(new(backups.Line, "stdout_logfile_backups", "NeedsRepair", $"Use 0–{ConfigurationValidator.MaxLogSegments} backups; the default is kept."));
            }
            if (2 * segmentBytes * (segments + 1L) > ConfigurationValidator.MaxLogBudgetBytes)
            {
                issues.Add(new(0, "stdout_logfile_maxbytes", "NeedsRepair", "Segment size and backups exceed the per-program log budget; defaults are kept."));
                segmentBytes = defaults.LogSegmentBytes; segments = defaults.LogSegments;
            }
            if (fields.TryGetValue("stopwaitsecs", out var stopField))
            {
                if (double.TryParse(stopField.Value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds) && seconds is >= 0 and <= 300) { stopWait = seconds; issues.Add(new(stopField.Line, "stopwaitsecs", "Mapped", "Mapped to the stop grace period.")); }
                else issues.Add(new(stopField.Line, "stopwaitsecs", "NeedsRepair", "Use 0–300 seconds; the default is kept."));
            }
            var codes = new List<uint>(); foreach (var raw in Get("exitcodes", "0").Split(',')) if (uint.TryParse(raw.Trim(), out var code)) codes.Add(code); else issues.Add(new(fields.GetValueOrDefault("exitcodes").Line, "exitcodes", "NeedsRepair", "Invalid DWORD exit code."));
            issues.Add(new(fields.GetValueOrDefault("command").Line, "command", "NeedsRepair", "Select explicit Windows execution mode and executable; no command translation."));
            issues.Add(new(0, "autostart", "Mapped", "Imported drafts are disabled; autostart is always false."));
            if (!seen.Add(ProgramNames.Key(name))) issues.Add(new(0, "name", "NeedsRepair", "Duplicate name; rename or skip."));
            drafts.Add(new(new()
            {
                Name = name,
                Notes = "Imported command (needs Windows repair): " + Get("command"),
                Enabled = false,
                Launch = new() { WorkingDirectory = Get("directory"), LogSegmentBytes = segmentBytes, LogSegments = segments, StopWaitSeconds = stopWait },
                Priority = Number("priority", 999),
                Policy = new() { Autostart = false, StartSeconds = Number("startsecs", 1), StartRetries = Number("startretries", 3), Restart = restart, ExpectedCodes = codes.Count == 0 ? [0] : codes.ToArray() }
            }, Get("command"), issues.ToArray()));
        }
        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim(); if (line.Length == 0 || line.StartsWith(';') || line.StartsWith('#')) continue;
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                Finish(); fields.Clear(); issues.Clear();
                var header = line[1..^1].Trim(); var section = header.StartsWith("program:", StringComparison.OrdinalIgnoreCase) ? header[8..].Trim() : "";
                name = section.Length == 0 ? null : section; continue;
            }
            if (name is null) continue;
            var eq = line.IndexOf('='); if (eq <= 0) { issues.Add(new(i + 1, "line", "Unsupported", "Expected key=value.")); continue; }
            var key = line[..eq].Trim(); var value = StripInlineComment(line[(eq + 1)..].Trim());
            if (!fields.TryAdd(key, (value, i + 1))) issues.Add(new(i + 1, key, "NeedsRepair", "Duplicate field."));
            if (!Supported.Contains(key) || value.Contains("%(")) issues.Add(new(i + 1, key, "Unsupported", "Unsupported field or interpolation; no expansion or includes are performed."));
            else if (key is "environment" or "directory" or "stopsignal" or "stopasgroup" or "killasgroup" || key.Contains("logfile") && key is not ("stdout_logfile_maxbytes" or "stdout_logfile_backups")) issues.Add(new(i + 1, key, "NeedsRepair", "Review Windows paths, environment, logging or stop semantics."));
        }
        Finish(); return drafts;
    }
}
