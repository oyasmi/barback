using System.Security.Cryptography;
using System.Text.Json;
using Barback.Core;
namespace Barback.Storage;

/// <summary>Application-level environment overrides shared by every program. One codec for the app and the settings window.</summary>
public static class ApplicationEnvironment
{
    public const string SettingKey = "application_environment";

    public static async Task<EnvironmentEntry[]> LoadAsync(SqliteStore store, ISecretProtector protector)
    {
        var value = await store.GetSettingAsync(SettingKey).ConfigureAwait(false);
        if (value is null) return [];
        var entries = JsonSerializer.Deserialize<EnvironmentEntry[]>(value) ?? [];
        return entries.Select(e => Decode(e, protector)).ToArray();
    }

    /// <summary>Values that cannot be decrypted (other account, lost DPAPI key) become re-entry placeholders instead of failing the load.</summary>
    public static EnvironmentEntry Decode(EnvironmentEntry entry, ISecretProtector protector)
    {
        if (!entry.Sensitive || entry.Remove) return entry with { Value = entry.Remove ? null : entry.Value, NeedsInput = false };
        if (entry.NeedsInput) return entry with { Value = null };
        try { return entry with { Value = protector.Unprotect(entry.Value ?? "") }; }
        catch (Exception ex) when (ex is InvalidOperationException or CryptographicException or FormatException) { return entry with { Value = null, NeedsInput = true }; }
    }

    public static EnvironmentEntry Encode(EnvironmentEntry entry, ISecretProtector protector)
    {
        if (entry.Remove) return entry with { Value = null, NeedsInput = false }; // a removal never carries a value, least of all a secret
        if (!entry.Sensitive) return entry with { NeedsInput = false };
        if (entry.NeedsInput) return entry with { Value = null };
        return entry with { Value = protector.Protect(entry.Value ?? "") };
    }

    public static Task SaveAsync(SqliteStore store, ISecretProtector protector, IEnumerable<EnvironmentEntry> entries) =>
        store.SetSettingAsync(SettingKey, JsonSerializer.Serialize(entries.Select(e => Encode(e, protector)).ToArray()));
}
