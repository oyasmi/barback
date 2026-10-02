using Barback.Core;
using Barback.Storage;
using Microsoft.Data.Sqlite;
namespace Barback.Storage.Tests;

public sealed class StoreTests : IAsyncLifetime
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "barback-store-" + Guid.NewGuid());
    private SqliteStore store = null!;
    private sealed class TestProtector : ISecretProtector
    {
        public string Protect(string s) => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("encrypted-test:" + s));
        public string Unprotect(string s) => System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(s))[15..];
    }
    public async Task InitializeAsync() => store = await SqliteStore.OpenAsync(root, new TestProtector());
    public async Task DisposeAsync() { await store.DisposeAsync(); Directory.Delete(root, true); }
    // Windows cannot delete databases while a pooled inspection connection retains its handle.
    private static SqliteConnection InspectDatabase(string path) => new(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
    private static ProgramConfig Draft(string name = "test") => new() { Name = name, Enabled = false };
    [Fact]
    public async Task OptimisticVersionAndUniqueNamesAreTransactional()
    {
        var first = await store.SaveAsync(Draft(), 0); Assert.Equal(1, first.Version);
        var second = await store.SaveAsync(first with { Name = "renamed" }, 1); Assert.Equal(2, second.Version);
        await Assert.ThrowsAsync<ConfigurationConflictException>(() => store.SaveAsync(first with { Name = "stale" }, 1));
        Assert.Equal("renamed", (await store.LoadProgramsAsync()).Single().Name);
        await Assert.ThrowsAsync<DuplicateProgramNameException>(() => store.SaveAsync(Draft("RENAMED"), 0)); Assert.Single(await store.LoadProgramsAsync());
    }
    [Fact]
    public async Task RunEndIsIdempotentAndPreservesUnsignedCodes()
    {
        var c = await store.SaveAsync(Draft(), 0); var r = new RunRecord(Guid.NewGuid(), c.Id, 1, 1, DateTimeOffset.UtcNow);
        await store.BeginRunAsync(r); await store.IdentifyRunAsync(r.Id, 123, 456); await store.EndRunAsync(r.Id, Phase.Failed, EndReason.Natural, 0xFFFFFFFF); await store.EndRunAsync(r.Id, Phase.Succeeded, EndReason.Natural, 0);
        var ended = (await store.RunsAsync()).Single(); Assert.Equal(uint.MaxValue, ended.ExitCode); Assert.Equal(Phase.Failed, ended.Outcome);
    }
    [Fact]
    public async Task CrashRecoveryRecordsUnknownInterruptedAndKeepsFatal()
    {
        Assert.False(await store.RecoverAsync());
        var c = await store.SaveAsync(Draft(), 0); await store.BeginRunAsync(new(Guid.NewGuid(), c.Id, 1, 1, DateTimeOffset.UtcNow));
        await store.SaveRuntimeAsync(c.Id, new() { Phase = Phase.Fatal, Error = "storm", RestartUtc = [DateTimeOffset.UtcNow], Deadline = double.PositiveInfinity });
        Assert.True(await store.RecoverAsync()); var run = (await store.RunsAsync()).Single(); Assert.Equal(Phase.Interrupted, run.Outcome); Assert.Null(run.ExitCode);
        Assert.Equal(Phase.Fatal, (await store.LoadRuntimeAsync())[c.Id].Phase);
    }
    [Fact]
    public async Task SecretsAreEncryptedAndPortableExportRemovesThem()
    {
        var c = Draft() with { Launch = new() { Environment = [new("TOKEN", "ultra-private", true)] } }; await store.SaveAsync(c, 0);
        Assert.Equal("ultra-private", (await store.LoadProgramsAsync()).Single().Launch.Environment.Single().Value);
        using var db = InspectDatabase(Path.Combine(root, "barback.db")); await db.OpenAsync(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT json FROM programs"; Assert.DoesNotContain("ultra-private", (string)(await cmd.ExecuteScalarAsync())!);
        var export = Path.Combine(root, "export.json"); await store.ExportPortableAsync(export); Assert.DoesNotContain("ultra-private", await File.ReadAllTextAsync(export));
        Assert.DoesNotContain("ultra-private", await File.ReadAllTextAsync(Directory.GetFiles(Path.Combine(root, "backups"), "config-*.json").Single()));
    }
    [Fact]
    public async Task OnlineBackupIncludesWalWrites()
    {
        await store.SaveAsync(Draft(), 0); var path = Path.Combine(root, "backup.db"); await store.BackupDatabaseAsync(path);
        using var backup = InspectDatabase(path); await backup.OpenAsync(); using var cmd = backup.CreateCommand(); cmd.CommandText = "SELECT count(*) FROM programs"; Assert.Equal(1L, await cmd.ExecuteScalarAsync());
    }
    [Fact]
    public async Task UnreadableSecretDisablesConfigurationAndRequiresReentry()
    {
        await store.SaveAsync(Draft() with { Enabled = true, Launch = new() { Environment = [new("TOKEN", "private", true)] } }, 0);
        using (var db = InspectDatabase(Path.Combine(root, "barback.db")))
        {
            await db.OpenAsync(); using var cmd = db.CreateCommand(); cmd.CommandText = "UPDATE programs SET json=json_set(json,'$.Launch.Environment[0].Value','invalid-base64')"; await cmd.ExecuteNonQueryAsync();
        }
        var loaded = (await store.LoadProgramsAsync()).Single(); Assert.False(loaded.Enabled); Assert.True(loaded.Launch.Environment.Single().NeedsInput); Assert.Null(loaded.Launch.Environment.Single().Value);
    }
    [Fact]
    public async Task CorruptDatabaseSourceIsPreserved()
    {
        var damaged = Path.Combine(root, "damaged"); Directory.CreateDirectory(damaged); var path = Path.Combine(damaged, "barback.db"); var bytes = System.Text.Encoding.UTF8.GetBytes("not a database"); await File.WriteAllBytesAsync(path, bytes);
        await Assert.ThrowsAsync<SqliteException>(() => SqliteStore.OpenAsync(damaged)); Assert.Equal(bytes, await File.ReadAllBytesAsync(path));
    }
    [Fact]
    public async Task SchemaOneMigrationBacksUpAndPreservesConfigurationAndHistory()
    {
        var migrationRoot = Path.Combine(root, "migration");
        var config = Draft("migration"); var run = new RunRecord(Guid.NewGuid(), config.Id, 1, 1, DateTimeOffset.UtcNow);
        await using (var old = await SqliteStore.OpenAsync(migrationRoot, new TestProtector()))
        {
            await old.SaveAsync(config, 0); await old.BeginRunAsync(run);
        }
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(migrationRoot, "barback.db"), Pooling = false }.ToString()))
        {
            await db.OpenAsync(); using var cmd = db.CreateCommand(); cmd.CommandText = "DROP TABLE output_cleanup; PRAGMA user_version=1"; await cmd.ExecuteNonQueryAsync();
        }
        await using (var upgraded = await SqliteStore.OpenAsync(migrationRoot, new TestProtector()))
        {
            Assert.Equal(config.Id, (await upgraded.LoadProgramsAsync()).Single().Id);
            Assert.Equal(run.Id, (await upgraded.RunsAsync()).Single().Id);
            await upgraded.DeleteAsync(config.Id); Assert.Empty(await upgraded.RunsAsync());
        }
        var backup = Directory.GetFiles(Path.Combine(migrationRoot, "backups"), "pre-migration-*.db").Single();
        using var original = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = backup, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()); await original.OpenAsync();
        using var check = original.CreateCommand(); check.CommandText = "PRAGMA user_version"; Assert.Equal(1L, await check.ExecuteScalarAsync());
        check.CommandText = "SELECT count(*) FROM runs"; Assert.Equal(1L, await check.ExecuteScalarAsync());
    }
    [Fact]
    public async Task HigherSchemaIsRejectedWithoutWriting()
    {
        var newer = Path.Combine(root, "newer"); Directory.CreateDirectory(newer);
        using (var db = InspectDatabase(Path.Combine(newer, "barback.db"))) { db.Open(); using var cmd = db.CreateCommand(); cmd.CommandText = "PRAGMA user_version=999"; cmd.ExecuteNonQuery(); }
        await Assert.ThrowsAsync<InvalidDataException>(() => SqliteStore.OpenAsync(newer));
    }
    [Fact]
    public async Task DeleteCleansOwnedOutputAndLeavesExternalFiles()
    {
        var c = await store.SaveAsync(Draft(), 0); var ownedRun = Guid.NewGuid(); var dir = Path.Combine(root, "logs", "runs", ownedRun.ToString("N"), ownedRun.ToString("N")); Directory.CreateDirectory(dir); await File.WriteAllTextAsync(Path.Combine(dir, "stdout.log"), "owned");
        await store.BeginRunAsync(new(ownedRun, c.Id, 1, 1, DateTimeOffset.UtcNow, LogDirectory: dir)); await store.EndRunAsync(ownedRun, Phase.Succeeded, EndReason.Natural, 0);
        var external = Path.Combine(root, "external"); Directory.CreateDirectory(external); await File.WriteAllTextAsync(Path.Combine(external, "stdout.log"), "user-owned"); var other = Guid.NewGuid(); await store.BeginRunAsync(new(other, c.Id, 2, 1, DateTimeOffset.UtcNow, LogDirectory: external)); await store.EndRunAsync(other, Phase.Succeeded, EndReason.Natural, 0);
        await store.DeleteAsync(c.Id); Assert.Empty(await store.LoadProgramsAsync()); Assert.Empty(await store.RunsAsync()); Assert.False(Directory.Exists(dir)); Assert.Equal("user-owned", await File.ReadAllTextAsync(Path.Combine(external, "stdout.log")));
    }
    [Fact]
    public async Task DuplicateImportRollsBackEntireBatch()
    {
        await store.SaveAsync(Draft("exists"), 0);
        var duplicate = await Assert.ThrowsAsync<DuplicateProgramNameException>(() => store.ImportAsync([Draft("new"), Draft("EXISTS")])); Assert.Equal(["EXISTS"], duplicate.Names);
        Assert.Equal("exists", (await store.LoadProgramsAsync()).Single().Name);
    }
    [Fact]
    public async Task RunRetentionKeepsActiveOutputAndCumulativeCount()
    {
        var c = await store.SaveAsync(Draft() with { Policy = new() { HistoryLimit = 2 } }, 0);
        var paths = new List<string>();
        for (int i = 0; i < 5; i++)
        {
            var id = Guid.NewGuid(); var dir = Path.Combine(root, "logs", "runs", id.ToString("N"), id.ToString("N")); Directory.CreateDirectory(dir); await File.WriteAllBytesAsync(Path.Combine(dir, "stdout.log"), new byte[100]); paths.Add(dir);
            await store.BeginRunAsync(new(id, c.Id, i, 1, DateTimeOffset.UtcNow.AddSeconds(i), LogDirectory: dir)); await store.EndRunAsync(id, Phase.Succeeded, EndReason.Natural, 0);
        }
        var active = Guid.NewGuid(); var activeDir = Path.Combine(root, "logs", "runs", active.ToString("N"), active.ToString("N")); Directory.CreateDirectory(activeDir); await File.WriteAllTextAsync(Path.Combine(activeDir, "stdout.log"), "active"); await store.BeginRunAsync(new(active, c.Id, 6, 1, DateTimeOffset.UtcNow.AddSeconds(6), LogDirectory: activeDir));
        await store.MaintainAsync(); Assert.Equal(3, (await store.RunsAsync()).Count); Assert.True(File.Exists(Path.Combine(activeDir, "stdout.log"))); Assert.False(Directory.Exists(paths[0])); Assert.False(Directory.Exists(Path.GetDirectoryName(paths[0])), "empty owner parent is removed with the run output"); Assert.True(Directory.Exists(paths[4]));
        using var db = InspectDatabase(Path.Combine(root, "barback.db")); await db.OpenAsync(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT total_runs FROM programs"; Assert.Equal(6L, await cmd.ExecuteScalarAsync());
    }
    [Fact]
    public async Task ConfigBackupRetentionKeepsTenSnapshots()
    {
        var c = await store.SaveAsync(Draft(), 0); for (int i = 0; i < 12; i++) c = await store.SaveAsync(c, c.Version);
        Assert.Equal(10, Directory.GetFiles(Path.Combine(root, "backups"), "config-*.json").Length);
    }
    private sealed class ForeignKeyProtector : ISecretProtector
    {
        // Mimics DPAPI after a restore on another account: only values written by this protector decrypt.
        public string Protect(string s) => "mine:" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(s));
        public string Unprotect(string s) => s.StartsWith("mine:", StringComparison.Ordinal) ? System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(s[5..])) : throw new InvalidOperationException("Sensitive value cannot be decrypted.");
    }
    [Fact] // F6
    public async Task ApplicationEnvironmentLoadsUndecryptableSecretsAsNeedsInput()
    {
        var protector = new ForeignKeyProtector();
        await store.SetSettingAsync(ApplicationEnvironment.SettingKey, System.Text.Json.JsonSerializer.Serialize(new[]
        {
            new EnvironmentEntry("PLAIN", "1"), new EnvironmentEntry("GOOD", new ForeignKeyProtector().Protect("ok"), true), new EnvironmentEntry("BAD", "foreign-cipher", true), new EnvironmentEntry("DROP", null, false, true)
        }));
        var loaded = await ApplicationEnvironment.LoadAsync(store, protector);
        Assert.Equal("ok", loaded.Single(e => e.Key == "GOOD").Value); Assert.False(loaded.Single(e => e.Key == "GOOD").NeedsInput);
        var bad = loaded.Single(e => e.Key == "BAD"); Assert.True(bad.NeedsInput); Assert.Null(bad.Value);
        Assert.False(loaded.Single(e => e.Key == "PLAIN").NeedsInput);
    }
    [Fact] // F6
    public async Task ApplicationEnvironmentSaveKeepsNeedsInputAndNeverStoresPlaintext()
    {
        var protector = new ForeignKeyProtector();
        await ApplicationEnvironment.SaveAsync(store, protector, [new("KEEP", null, true, false, true), new("NEW", "s3cret", true), new("GONE", "leftover", true, true), new("PLAIN", "v")]);
        var raw = (await store.GetSettingAsync(ApplicationEnvironment.SettingKey))!;
        Assert.DoesNotContain("s3cret", raw); Assert.DoesNotContain("leftover", raw);
        var loaded = await ApplicationEnvironment.LoadAsync(store, protector);
        Assert.True(loaded.Single(e => e.Key == "KEEP").NeedsInput); Assert.Equal("s3cret", loaded.Single(e => e.Key == "NEW").Value);
        Assert.True(loaded.Single(e => e.Key == "GONE").Remove); Assert.Equal("v", loaded.Single(e => e.Key == "PLAIN").Value);
    }
    private static string Backup(bool encrypted, string secret, string? platform = "windows", int schema = 2) =>
        System.Text.Json.JsonSerializer.Serialize(new { schemaVersion = schema, sourcePlatform = platform, encryptedSecrets = encrypted, programs = new[] { new ProgramConfig { Name = "web", Enabled = true, Policy = new() { Autostart = true }, Launch = new() { Environment = [new("TOKEN", secret, true), new("PLAIN", "1")] } } } });
    [Fact] // F12
    public void BackupReaderTurnsUndecryptableSecretsIntoReentryPlaceholders()
    {
        var protector = new ForeignKeyProtector(); var good = protector.Protect("ok");
        var restored = ConfigurationBackupReader.Read(Backup(true, good), protector).Single();
        Assert.False(restored.Enabled); Assert.False(restored.Policy.Autostart); Assert.Equal(0, restored.Version);
        Assert.Equal("ok", restored.Launch.Environment.Single(e => e.Key == "TOKEN").Value);
        var foreign = ConfigurationBackupReader.Read(Backup(true, "cipher-from-another-account"), protector).Single().Launch.Environment.Single(e => e.Key == "TOKEN");
        Assert.True(foreign.NeedsInput); Assert.Null(foreign.Value);
        var plain = ConfigurationBackupReader.Read(Backup(false, "portable-export"), protector).Single().Launch.Environment.Single(e => e.Key == "TOKEN");
        Assert.True(plain.NeedsInput); Assert.Null(plain.Value);
    }
    [Theory] // F12
    [InlineData("macos", 2)]
    [InlineData("windows", 99)]
    public void BackupReaderRejectsForeignPlatformOrSchema(string platform, int schema) =>
        Assert.Throws<InvalidDataException>(() => ConfigurationBackupReader.Read(Backup(true, "x", platform, schema), new ForeignKeyProtector()));
    [Fact] // S3
    public async Task DeletingAProgramAlsoRemovesItsEmptyServiceOutputDirectory()
    {
        var c = await store.SaveAsync(Draft(), 0); var run = Guid.NewGuid();
        var parent = Path.Combine(root, "logs", "programs", c.Id.ToString("N")); var dir = Path.Combine(parent, run.ToString("N")); Directory.CreateDirectory(dir);
        await File.WriteAllTextAsync(Path.Combine(dir, "stdout.log"), "x"); await File.WriteAllTextAsync(Path.Combine(dir, "stdout.log.gaps"), "gap");
        await store.BeginRunAsync(new(run, c.Id, 1, 1, DateTimeOffset.UtcNow, LogDirectory: dir)); await store.EndRunAsync(run, Phase.Exited, EndReason.Natural, 0);
        await store.DeleteAsync(c.Id); Assert.False(Directory.Exists(dir)); Assert.False(Directory.Exists(parent));
    }
    [Fact] // S3
    public async Task OwnerParentWithOtherContentIsKept()
    {
        var c = await store.SaveAsync(Draft(), 0); var run = Guid.NewGuid(); var other = Guid.NewGuid();
        var parent = Path.Combine(root, "logs", "programs", c.Id.ToString("N")); var dir = Path.Combine(parent, run.ToString("N")); var sibling = Path.Combine(parent, other.ToString("N")); Directory.CreateDirectory(dir); Directory.CreateDirectory(sibling);
        await File.WriteAllTextAsync(Path.Combine(dir, "stdout.log"), "x"); await store.BeginRunAsync(new(run, c.Id, 1, 1, DateTimeOffset.UtcNow, LogDirectory: dir)); await store.EndRunAsync(run, Phase.Exited, EndReason.Natural, 0);
        await store.DeleteAsync(c.Id); Assert.False(Directory.Exists(dir)); Assert.True(Directory.Exists(sibling), "foreign content keeps the parent in place");
    }
    [Fact] // S2
    public async Task EventTableIsTrimmedByMaintenanceNotByEveryInsert()
    {
        using (var db = InspectDatabase(Path.Combine(root, "barback.db")))
        {
            await db.OpenAsync(); using var cmd = db.CreateCommand();
            cmd.CommandText = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<50100) INSERT INTO events(at,type,detail) SELECT $at,'Bulk','x' FROM n";
            cmd.Parameters.AddWithValue("$at", DateTimeOffset.UtcNow.ToString("O")); await cmd.ExecuteNonQueryAsync();
            cmd.CommandText = "INSERT INTO events(at,type,detail) VALUES('2000-01-01T00:00:00.0000000+00:00','Ancient','old')"; await cmd.ExecuteNonQueryAsync();
        }
        await store.EventAsync(new(DateTimeOffset.UtcNow, "Fresh", null, null, "one")); // a single insert must not scan or trim
        using (var db = InspectDatabase(Path.Combine(root, "barback.db"))) { await db.OpenAsync(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT COUNT(*) FROM events"; Assert.Equal(50102L, await cmd.ExecuteScalarAsync()); }
        await store.MaintainAsync();
        using (var db = InspectDatabase(Path.Combine(root, "barback.db"))) { await db.OpenAsync(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT COUNT(*) FROM events"; Assert.Equal(49999L, await cmd.ExecuteScalarAsync()); /* newest 50,000 by id, minus the expired row among them */ cmd.CommandText = "SELECT COUNT(*) FROM events WHERE type='Ancient'"; Assert.Equal(0L, await cmd.ExecuteScalarAsync()); cmd.CommandText = "SELECT COUNT(*) FROM events WHERE type='Fresh'"; Assert.Equal(1L, await cmd.ExecuteScalarAsync()); }
    }
    [Fact] // S1
    public async Task MaintenanceTreatsEveryEndedOutcomeAsCompleted()
    {
        var c = await store.SaveAsync(Draft() with { Policy = new() { HistoryLimit = 1 } }, 0);
        for (int i = 0; i < 3; i++) { var id = Guid.NewGuid(); await store.BeginRunAsync(new(id, c.Id, i, 1, DateTimeOffset.UtcNow.AddSeconds(i))); await store.EndRunAsync(id, Phase.Interrupted, EndReason.AppInterrupted, null); }
        await store.MaintainAsync(); Assert.Single(await store.RunsAsync());
    }
}
