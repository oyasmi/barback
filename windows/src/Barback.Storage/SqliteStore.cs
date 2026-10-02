using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Barback.Core;
using Microsoft.Data.Sqlite;
namespace Barback.Storage;

public interface ISecretProtector { string Protect(string plaintext); string Unprotect(string ciphertext); }
public sealed class DpapiProtector : ISecretProtector
{
    public string Protect(string plaintext)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("DPAPI requires Windows.");
        return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(plaintext), null, DataProtectionScope.CurrentUser));
    }
    public string Unprotect(string ciphertext)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("DPAPI requires Windows.");
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(ciphertext), null, DataProtectionScope.CurrentUser)); }
        catch (CryptographicException ex) { throw new InvalidOperationException("Sensitive value cannot be decrypted; enter it again using this Windows account.", ex); }
    }
}
public sealed class SqliteStore : IStore
{
    public const int SchemaVersion = 2;
    public static bool AcceptsConfigurationSchema(int version) => version is >= 1 and <= SchemaVersion;
    private readonly SqliteConnection db;
    private readonly SemaphoreSlim gate = new(1);
    private readonly ISecretProtector secrets;
    public string Root { get; }
    public LogQuota? LogQuota { get; set; }
    private SqliteStore(string root, SqliteConnection db, ISecretProtector secrets) { Root = root; this.db = db; this.secrets = secrets; }
    public static Task<SqliteStore> OpenAsync(string root, ISecretProtector? secrets = null) => Task.Run(() => OpenInternalAsync(root, secrets));
    private static async Task<SqliteStore> OpenInternalAsync(string root, ISecretProtector? secrets)
    {
        Directory.CreateDirectory(root); var path = Path.Combine(root, "barback.db");
        var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWriteCreate, DefaultTimeout = 5, Pooling = false }.ToString());
        try
        {
            await db.OpenAsync();
            using var check = db.CreateCommand(); check.CommandText = "PRAGMA quick_check";
            if ((string?)await check.ExecuteScalarAsync() != "ok") throw new InvalidDataException("Database integrity check failed. Source preserved; restore a backup before running.");
            check.CommandText = "PRAGMA user_version"; int version = Convert.ToInt32(await check.ExecuteScalarAsync());
            if (version > SchemaVersion) throw new InvalidDataException("Database requires a newer Barback version.");
            if (version < SchemaVersion && new FileInfo(path).Length > 0)
            {
                Directory.CreateDirectory(Path.Combine(root, "backups"));
                using var backup = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(root, "backups", $"pre-migration-{DateTime.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}.db"), Pooling = false }.ToString()); backup.Open(); db.BackupDatabase(backup);
            }
            check.CommandText = "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"; await check.ExecuteNonQueryAsync();
            using var tx = db.BeginTransaction(); check.Transaction = tx;
            check.CommandText = """
                CREATE TABLE IF NOT EXISTS programs(id TEXT PRIMARY KEY,name_key TEXT UNIQUE NOT NULL,version INTEGER NOT NULL,json TEXT NOT NULL,total_runs INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,program_id TEXT NOT NULL REFERENCES programs(id) ON DELETE CASCADE,generation INTEGER NOT NULL,config_version INTEGER NOT NULL,started TEXT NOT NULL,ended TEXT,pid INTEGER,creation_time INTEGER,outcome INTEGER NOT NULL,reason INTEGER,exit_code INTEGER,log_directory TEXT);
                CREATE TABLE IF NOT EXISTS runtime(program_id TEXT PRIMARY KEY REFERENCES programs(id) ON DELETE CASCADE,json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY,at TEXT NOT NULL,type TEXT NOT NULL,program_id TEXT,run_id TEXT,detail TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS output_cleanup(run_id TEXT PRIMARY KEY,program_id TEXT NOT NULL,directory TEXT NOT NULL);
                PRAGMA user_version=2;
                """;
            await check.ExecuteNonQueryAsync(); tx.Commit();
            return new(root, db, secrets ?? new DpapiProtector());
        }
        catch { await db.DisposeAsync(); throw; }
    }
    private async Task<T> Locked<T>(Func<Task<T>> action) { await gate.WaitAsync(); try { return await Task.Run(action); } finally { gate.Release(); } }
    private Task Locked(Func<Task> action) => Locked(async () => { await action(); return true; });
    private SqliteCommand Command(string sql, params (string Name, object? Value)[] values)
    {
        var cmd = db.CreateCommand(); cmd.CommandText = sql;
        foreach (var (name, value) in values) cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return cmd;
    }
    private ProgramConfig Encode(ProgramConfig c) => c with { Launch = c.Launch with { Environment = c.Launch.Environment.Select(e => e.Sensitive && !e.Remove && !e.NeedsInput ? e with { Value = secrets.Protect(e.Value ?? "") } : e).ToArray() } };
    private ProgramConfig Decode(ProgramConfig c)
    {
        EnvironmentEntry DecodeEntry(EnvironmentEntry e)
        {
            if (!e.Sensitive || e.Remove || e.NeedsInput) return e;
            try { return e with { Value = secrets.Unprotect(e.Value ?? "") }; }
            catch (Exception ex) when (ex is InvalidOperationException or CryptographicException or FormatException) { return e with { Value = null, NeedsInput = true }; }
        }
        var decoded = c with { Launch = c.Launch with { Environment = c.Launch.Environment.Select(DecodeEntry).ToArray() } };
        return decoded.Launch.Environment.Any(e => e.NeedsInput) ? decoded with { Enabled = false } : decoded;
    }
    public Task<IReadOnlyList<ProgramConfig>> LoadProgramsAsync() => Locked<IReadOnlyList<ProgramConfig>>(async () =>
    {
        using var cmd = Command("SELECT json FROM programs ORDER BY name_key"); using var reader = await cmd.ExecuteReaderAsync(); var result = new List<ProgramConfig>();
        while (await reader.ReadAsync()) result.Add(Decode(JsonSerializer.Deserialize<ProgramConfig>(reader.GetString(0))!)); return result;
    });
    /// <summary>Maps the expected user-facing constraint violations to typed exceptions; anything else stays a storage fault.</summary>
    private static Exception? ToTypedException(SqliteException ex, IEnumerable<string> names)
    {
        if (ex.SqliteErrorCode != 19) return null;
        if (ex.Message.Contains("programs.name_key", StringComparison.Ordinal)) return new DuplicateProgramNameException(names, ex);
        if (ex.Message.Contains("programs.id", StringComparison.Ordinal)) return new ConfigurationConflictException(inner: ex);
        return null;
    }
    public Task<ProgramConfig> SaveAsync(ProgramConfig c, long expectedVersion) => Locked(async () =>
    {
        var next = c with { Version = expectedVersion + 1 }; var encoded = Encode(next);
        using var tx = db.BeginTransaction();
        using var cmd = expectedVersion == 0 ? Command("INSERT INTO programs(id,name_key,version,json) VALUES($id,$name,$version,$json)", ("$id", c.Id.ToString()), ("$name", c.NameKey), ("$version", next.Version), ("$json", JsonSerializer.Serialize(encoded))) :
            Command("UPDATE programs SET name_key=$name,version=$version,json=$json WHERE id=$id AND version=$expected", ("$id", c.Id.ToString()), ("$name", c.NameKey), ("$version", next.Version), ("$json", JsonSerializer.Serialize(encoded)), ("$expected", expectedVersion));
        cmd.Transaction = tx;
        int changed;
        try { changed = await cmd.ExecuteNonQueryAsync(); }
        catch (SqliteException ex) when (ToTypedException(ex, [c.Name]) is { } typed) { throw typed; }
        if (changed != 1) throw new ConfigurationConflictException();
        tx.Commit();
        // The durable save has succeeded; a backup failure is recorded without reporting a false save failure.
        try { await BackupConfigInternalAsync(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { using var warn = Command("INSERT INTO events(at,type,detail) VALUES($at,'BackupFailed','Configuration saved; backup could not be written.')", ("$at", DateTimeOffset.UtcNow.ToString("O"))); try { await warn.ExecuteNonQueryAsync(); } catch (SqliteException) { } }
        return next;
    });

    public Task<IReadOnlyList<ProgramConfig>> ImportAsync(IReadOnlyList<ProgramConfig> drafts) => Locked<IReadOnlyList<ProgramConfig>>(async () =>
    {
        using var tx = db.BeginTransaction(); var result = new List<ProgramConfig>();
        foreach (var draft in drafts)
        {
            var c = draft with { Version = 1, Enabled = false, Policy = draft.Policy with { Autostart = false } };
            using var cmd = Command("INSERT INTO programs(id,name_key,version,json) VALUES($id,$name,1,$json)", ("$id", c.Id.ToString()), ("$name", c.NameKey), ("$json", JsonSerializer.Serialize(Encode(c))));
            cmd.Transaction = tx;
            try { await cmd.ExecuteNonQueryAsync(); }
            catch (SqliteException ex) when (ToTypedException(ex, [c.Name]) is { } typed) { throw typed; }
            result.Add(c);
        }
        tx.Commit();
        try { await BackupConfigInternalAsync(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        return result;
    });
    public Task DeleteAsync(Guid id) => Locked(async () =>
    {
        using var tx = db.BeginTransaction();
        using var cmd = Command("INSERT OR IGNORE INTO output_cleanup SELECT id,program_id,log_directory FROM runs WHERE program_id=$id AND log_directory IS NOT NULL; DELETE FROM programs WHERE id=$id", ("$id", id.ToString()));
        cmd.Transaction = tx; await cmd.ExecuteNonQueryAsync(); tx.Commit();
        await RetryOutputCleanupAsync();
    });
    public Task BeginRunAsync(RunRecord r) => Locked(async () =>
    {
        using var tx = db.BeginTransaction();
        using var cmd = Command("INSERT INTO runs(id,program_id,generation,config_version,started,outcome,log_directory) VALUES($id,$p,$g,$v,$s,$o,$l)", ("$id", r.Id.ToString()), ("$p", r.ProgramId.ToString()), ("$g", r.Generation), ("$v", r.ConfigVersion), ("$s", r.Started.ToString("O")), ("$o", (int)Phase.Starting), ("$l", r.LogDirectory));
        cmd.Transaction = tx; await cmd.ExecuteNonQueryAsync();
        cmd.CommandText = "UPDATE programs SET total_runs=total_runs+1 WHERE id=$p"; await cmd.ExecuteNonQueryAsync(); tx.Commit();
    });
    public Task IdentifyRunAsync(Guid id, int pid, long time) => Locked(async () => { using var cmd = Command("UPDATE runs SET pid=$pid,creation_time=$time,outcome=$o WHERE id=$id AND ended IS NULL", ("$pid", pid), ("$time", time), ("$o", (int)Phase.Running), ("$id", id.ToString())); await cmd.ExecuteNonQueryAsync(); });
    public Task EndRunAsync(Guid id, Phase outcome, EndReason reason, uint? code) => Locked(async () =>
    {
        using var cmd = Command("UPDATE runs SET ended=$at,outcome=$o,reason=$r,exit_code=$c WHERE id=$id AND ended IS NULL", ("$at", DateTimeOffset.UtcNow.ToString("O")), ("$o", (int)outcome), ("$r", (int)reason), ("$c", code is uint u ? (long)u : null), ("$id", id.ToString())); await cmd.ExecuteNonQueryAsync();
    });
    public Task SaveRuntimeAsync(Guid id, RuntimeState state) => Locked(async () => { using var cmd = Command("INSERT INTO runtime VALUES($id,$json) ON CONFLICT(program_id) DO UPDATE SET json=excluded.json", ("$id", id.ToString()), ("$json", JsonSerializer.Serialize(state, JsonOptions))); await cmd.ExecuteNonQueryAsync(); });
    private static readonly JsonSerializerOptions JsonOptions = new() { NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowNamedFloatingPointLiterals };
    public Task<IReadOnlyDictionary<Guid, RuntimeState>> LoadRuntimeAsync() => Locked<IReadOnlyDictionary<Guid, RuntimeState>>(async () =>
    {
        using var cmd = Command("SELECT program_id,json FROM runtime"); using var reader = await cmd.ExecuteReaderAsync(); var result = new Dictionary<Guid, RuntimeState>();
        while (await reader.ReadAsync()) result.Add(Guid.Parse(reader.GetString(0)), JsonSerializer.Deserialize<RuntimeState>(reader.GetString(1), JsonOptions)!); return result;
    });
    public Task<IReadOnlyList<RunRecord>> RunsAsync() => Locked<IReadOnlyList<RunRecord>>(async () =>
    {
        using var cmd = Command("SELECT id,program_id,generation,config_version,started,ended,pid,creation_time,outcome,reason,exit_code,log_directory FROM runs ORDER BY started DESC LIMIT 5000");
        using var r = await cmd.ExecuteReaderAsync(); var result = new List<RunRecord>();
        while (await r.ReadAsync()) result.Add(new(Guid.Parse(r.GetString(0)), Guid.Parse(r.GetString(1)), r.GetInt64(2), r.GetInt64(3), DateTimeOffset.Parse(r.GetString(4)), r.IsDBNull(5) ? null : DateTimeOffset.Parse(r.GetString(5)), r.IsDBNull(6) ? null : r.GetInt32(6), r.IsDBNull(7) ? null : r.GetInt64(7), (Phase)r.GetInt32(8), r.IsDBNull(9) ? null : (EndReason)r.GetInt32(9), r.IsDBNull(10) ? null : checked((uint)r.GetInt64(10)), r.IsDBNull(11) ? null : r.GetString(11))); return result;
    });
    public Task EventAsync(EventRecord e) => Locked(async () =>
    {
        using var cmd = Command("INSERT INTO events(at,type,program_id,run_id,detail) VALUES($at,$type,$p,$r,$d); DELETE FROM events WHERE at<$cut OR id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 50000)", ("$at", e.At.ToString("O")), ("$type", e.Type), ("$p", e.ProgramId?.ToString()), ("$r", e.RunId?.ToString()), ("$d", e.Detail), ("$cut", DateTimeOffset.UtcNow.AddDays(-30).ToString("O"))); await cmd.ExecuteNonQueryAsync();
    });
    public Task<IReadOnlyList<EventRecord>> EventsAsync() => Locked<IReadOnlyList<EventRecord>>(async () =>
    {
        using var cmd = Command("SELECT at,type,program_id,run_id,detail FROM events ORDER BY id DESC LIMIT 5000"); using var r = await cmd.ExecuteReaderAsync(); var result = new List<EventRecord>();
        while (await r.ReadAsync()) result.Add(new(DateTimeOffset.Parse(r.GetString(0)), r.GetString(1), r.IsDBNull(2) ? null : Guid.Parse(r.GetString(2)), r.IsDBNull(3) ? null : Guid.Parse(r.GetString(3)), r.GetString(4))); return result;
    });
    public Task<bool> RecoverAsync() => Locked(async () =>
    {
        using var cmd = Command("SELECT value FROM settings WHERE key='clean_shutdown'"); bool interrupted = (string?)await cmd.ExecuteScalarAsync() == "false";
        cmd.CommandText = "UPDATE runs SET ended=$at,outcome=$out,reason=$reason,exit_code=NULL WHERE ended IS NULL; INSERT INTO settings VALUES('clean_shutdown','false') ON CONFLICT(key) DO UPDATE SET value='false'";
        cmd.Parameters.AddWithValue("$at", DateTimeOffset.UtcNow.ToString("O")); cmd.Parameters.AddWithValue("$out", (int)Phase.Interrupted); cmd.Parameters.AddWithValue("$reason", (int)EndReason.AppInterrupted); await cmd.ExecuteNonQueryAsync(); return interrupted;
    });
    public Task MarkCleanAsync() => Locked(async () => { using var cmd = Command("INSERT INTO settings VALUES('clean_shutdown','true') ON CONFLICT(key) DO UPDATE SET value='true'"); await cmd.ExecuteNonQueryAsync(); });
    public Task BackupDatabaseAsync(string destination) => Locked(() => { using var backup = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = destination, Pooling = false }.ToString()); backup.Open(); db.BackupDatabase(backup); return Task.CompletedTask; });
    private async Task BackupConfigInternalAsync()
    {
        using var cmd = Command("SELECT json FROM programs ORDER BY name_key"); using var r = await cmd.ExecuteReaderAsync(); var configs = new List<JsonElement>();
        while (await r.ReadAsync()) configs.Add(JsonSerializer.Deserialize<JsonElement>(r.GetString(0)));
        var data = JsonSerializer.SerializeToUtf8Bytes(new { schemaVersion = SchemaVersion, sourcePlatform = "windows", encryptedSecrets = true, programs = configs });
        var dir = Path.Combine(Root, "backups"); Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, $"config-{DateTime.UtcNow:yyyyMMddHHmmssfffffff}.json");
        await File.WriteAllBytesAsync(file + ".tmp", data); File.Move(file + ".tmp", file);
        foreach (var old in Directory.GetFiles(dir, "config-*.json").OrderDescending().Skip(10)) File.Delete(old);
    }
    public async Task ExportPortableAsync(string path)
    {
        var configs = await LoadProgramsAsync();
        var safe = configs.Select(c => c with { Enabled = false, Policy = c.Policy with { Autostart = false }, Launch = c.Launch with { Environment = c.Launch.Environment.Select(e => e.Sensitive ? e with { Value = null, NeedsInput = true } : e).ToArray() } });
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(new { schemaVersion = SchemaVersion, sourcePlatform = "windows", programs = safe }, new JsonSerializerOptions { WriteIndented = true }));
    }
    public Task<string?> GetSettingAsync(string key) => Locked(async () => { using var cmd = Command("SELECT value FROM settings WHERE key=$key", ("$key", key)); return (string?)await cmd.ExecuteScalarAsync(); });
    public Task SetSettingAsync(string key, string value) => Locked(async () => { using var cmd = Command("INSERT INTO settings VALUES($key,$v) ON CONFLICT(key) DO UPDATE SET value=excluded.value", ("$key", key), ("$v", value)); await cmd.ExecuteNonQueryAsync(); });

    private bool RemoveOwnedOutput(Guid program, Guid run, string directory)
    {
        var expectedService = Path.Combine(Root, "logs", "programs", program.ToString("N"), run.ToString("N"));
        var expectedRun = Path.Combine(Root, "logs", "runs", run.ToString("N"), run.ToString("N"));
        var path = Path.GetFullPath(directory);
        if (!path.Equals(expectedService, StringComparison.OrdinalIgnoreCase) && !path.Equals(expectedRun, StringComparison.OrdinalIgnoreCase)) return true; // External files remain untouched.
        if (!Directory.Exists(path)) return true;
        try
        {
            var parent = new DirectoryInfo(path);
            while (parent is not null && parent.FullName.StartsWith(Root, StringComparison.OrdinalIgnoreCase)) { if (parent.Attributes.HasFlag(FileAttributes.ReparsePoint)) return true; parent = parent.Parent; }
            long released = 0;
            foreach (var file in Directory.GetFiles(path))
            {
                var name = Path.GetFileName(file); if (!System.Text.RegularExpressions.Regex.IsMatch(name, @"^(stdout|stderr)\.log(?:\.[0-9]+|\.gaps)?$")) continue;
                var info = new FileInfo(file); if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue; var size = info.Length; File.Delete(file); if (!name.EndsWith(".gaps", StringComparison.Ordinal)) released += size;
            }
            LogQuota?.Release(released);
            if (!Directory.EnumerateFileSystemEntries(path).Any()) { Directory.Delete(path); return true; }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        return false;
    }
    private async Task RetryOutputCleanupAsync()
    {
        var pending = new List<(Guid Run, Guid Program, string Path)>();
        using (var cmd = Command("SELECT run_id,program_id,directory FROM output_cleanup LIMIT 1000")) using (var r = await cmd.ExecuteReaderAsync())
            while (await r.ReadAsync()) pending.Add((Guid.Parse(r.GetString(0)), Guid.Parse(r.GetString(1)), r.GetString(2)));
        foreach (var item in pending)
        {
            if (!RemoveOwnedOutput(item.Program, item.Run, item.Path)) continue;
            using var cmd = Command("DELETE FROM output_cleanup WHERE run_id=$id", ("$id", item.Run.ToString())); await cmd.ExecuteNonQueryAsync();
        }
    }
    /// <summary>Clean completed output until usage falls to 90 % of the global budget; without a budget nothing is trimmed.</summary>
    private bool OverQuotaTarget() => LogQuota is { } quota && quota.UsedBytes > (long)(quota.Limit * 0.9);
    public Task MaintainAsync() => Locked(async () =>
    {
        await RetryOutputCleanupAsync();
        var limits = new Dictionary<Guid, int>();
        using (var cmd = Command("SELECT id,json FROM programs")) using (var r = await cmd.ExecuteReaderAsync())
            while (await r.ReadAsync()) limits[Guid.Parse(r.GetString(0))] = JsonSerializer.Deserialize<ProgramConfig>(r.GetString(1))!.Policy.HistoryLimit;
        var completed = new List<(Guid Id, Guid Program, string Directory, bool Prune)>(); var counts = new Dictionary<Guid, int>();
        using (var cmd = Command("SELECT id,program_id,log_directory FROM runs WHERE ended IS NOT NULL AND outcome<>12 ORDER BY started DESC")) using (var r = await cmd.ExecuteReaderAsync())
            while (await r.ReadAsync()) { var program = Guid.Parse(r.GetString(1)); counts[program] = counts.GetValueOrDefault(program) + 1; completed.Add((Guid.Parse(r.GetString(0)), program, r.IsDBNull(2) ? "" : r.GetString(2), counts[program] > limits.GetValueOrDefault(program, 50))); }
        // Delete only directories derivable from immutable ownership IDs; never user-provided external files.
        foreach (var item in completed.Where(x => x.Prune).Concat(OverQuotaTarget() ? completed.Where(x => !x.Prune).Reverse() : []))
        {
            var expectedService = Path.Combine(Root, "logs", "programs", item.Program.ToString("N"), item.Id.ToString("N"));
            var expectedRun = Path.Combine(Root, "logs", "runs", item.Id.ToString("N"), item.Id.ToString("N"));
            var path = Path.GetFullPath(item.Directory.Length == 0 ? Root : item.Directory);
            if (item.Directory.Length > 0 && !path.Equals(expectedService, StringComparison.OrdinalIgnoreCase) && !path.Equals(expectedRun, StringComparison.OrdinalIgnoreCase)) continue;
            if (item.Directory.Length > 0 && Directory.Exists(path))
            {
                var parent = new DirectoryInfo(path); bool linked = false;
                while (parent is not null && parent.FullName.StartsWith(Root, StringComparison.OrdinalIgnoreCase)) { if (parent.Attributes.HasFlag(FileAttributes.ReparsePoint)) { linked = true; break; } parent = parent.Parent; }
                if (linked) continue;
                try
                {
                    long released = 0;
                    foreach (var file in Directory.GetFiles(path))
                    {
                        var name = Path.GetFileName(file); if (!name.StartsWith("stdout.log", StringComparison.Ordinal) && !name.StartsWith("stderr.log", StringComparison.Ordinal)) continue;
                        var info = new FileInfo(file); if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue; var size = info.Length; File.Delete(file); if (!name.EndsWith(".gaps", StringComparison.Ordinal)) released += size;
                    }
                    LogQuota?.Release(released); if (!Directory.EnumerateFileSystemEntries(path).Any()) Directory.Delete(path);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
            }
            using var delete = Command(item.Prune ? "DELETE FROM runs WHERE id=$id AND ended IS NOT NULL" : "UPDATE runs SET log_directory=NULL WHERE id=$id AND ended IS NOT NULL", ("$id", item.Id.ToString())); await delete.ExecuteNonQueryAsync();
            if (!item.Prune && !OverQuotaTarget()) break;
        }
    });
    public async ValueTask DisposeAsync() { await gate.WaitAsync(); try { await db.DisposeAsync(); } finally { gate.Release(); gate.Dispose(); } }
}
