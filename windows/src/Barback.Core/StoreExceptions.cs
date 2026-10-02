namespace Barback.Core;

/// <summary>Optimistic version check failed; the caller should reload and merge. Not a storage fault.</summary>
public sealed class ConfigurationConflictException(string? message = null, Exception? inner = null)
    : Exception(message ?? "Configuration version conflict. Preserve your draft and reload before saving.", inner);

/// <summary>Application-level sensitive variables cannot be decrypted, so no program can start until they are re-entered or removed.</summary>
public sealed class ApplicationEnvironmentNeedsInputException()
    : InvalidOperationException("Application environment contains sensitive values requiring re-entry. Open Settings / Environment.");

/// <summary>A program name collides (case-insensitively) with an existing one. Not a storage fault.</summary>
public sealed class DuplicateProgramNameException : Exception
{
    public IReadOnlyList<string> Names { get; }
    public DuplicateProgramNameException(IEnumerable<string> names, Exception? inner = null)
        : base("A program with this name already exists: " + string.Join(", ", names), inner) => Names = names.ToArray();
    public DuplicateProgramNameException(string name, Exception? inner = null) : this([name], inner) { }
}
