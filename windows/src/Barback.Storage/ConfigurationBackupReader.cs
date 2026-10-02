using System.Security.Cryptography;
using System.Text.Json;
using Barback.Core;
namespace Barback.Storage;

/// <summary>Reads configuration backups (automatic backups and portable exports) into safe, disabled drafts.</summary>
public static class ConfigurationBackupReader
{
    /// <summary>
    /// Every program gets a new Id, version 0, and is disabled without autostart. Sensitive values that cannot be
    /// decrypted (another account or machine, or an export without secrets) become re-entry placeholders; the rest of the backup still loads.
    /// </summary>
    public static IReadOnlyList<ProgramConfig> Read(string json, ISecretProtector protector)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("schemaVersion", out var version) || version.ValueKind != JsonValueKind.Number
            || !SqliteStore.AcceptsConfigurationSchema(version.GetInt32())
            || !root.TryGetProperty("sourcePlatform", out var platform) || platform.GetString() != "windows"
            || !root.TryGetProperty("programs", out var programs) || programs.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("Unsupported configuration backup.");
        bool encrypted = root.TryGetProperty("encryptedSecrets", out var flag) && flag.ValueKind == JsonValueKind.True;
        var result = new List<ProgramConfig>();
        foreach (var item in programs.EnumerateArray())
        {
            var config = item.Deserialize<ProgramConfig>() ?? throw new InvalidDataException("Unsupported configuration backup.");
            EnvironmentEntry Decode(EnvironmentEntry entry)
            {
                if (!entry.Sensitive || entry.Remove) return entry;
                if (!encrypted || entry.NeedsInput) return entry with { Value = null, NeedsInput = true };
                try { return entry with { Value = protector.Unprotect(entry.Value ?? "") }; }
                catch (Exception ex) when (ex is InvalidOperationException or CryptographicException or FormatException) { return entry with { Value = null, NeedsInput = true }; }
            }
            var restored = config with
            {
                Id = Guid.NewGuid(), Version = 0, Enabled = false, Policy = config.Policy with { Autostart = false },
                Launch = config.Launch with { Environment = config.Launch.Environment.Select(Decode).ToArray() }
            };
            var errors = ConfigurationValidator.Validate(restored, false);
            if (errors.Count > 0) throw new InvalidDataException(string.Join("\n", errors.Select(e => e.Message)));
            result.Add(restored);
        }
        return result;
    }
}
