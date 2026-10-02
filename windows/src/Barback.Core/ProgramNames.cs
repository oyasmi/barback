namespace Barback.Core;

public static class ProgramNames
{
    /// <summary>The comparison key used for uniqueness (case-insensitive, normalized, trimmed).</summary>
    public static string Key(string name) => new ProgramConfig { Name = name }.NameKey;

    /// <summary>
    /// Returns <paramref name="name"/> when free, otherwise the first free <c>name + suffix(n)</c> for n = 1, 2, … and reserves the result in
    /// <paramref name="usedNameKeys"/>. Callers supply localized suffixes such as "（恢复）", "（恢复 2）".
    /// </summary>
    public static string MakeUnique(string name, Func<int, string> suffix, ISet<string> usedNameKeys)
    {
        var candidate = name;
        for (int attempt = 1; !usedNameKeys.Add(Key(candidate)); attempt++) candidate = name + suffix(attempt);
        return candidate;
    }
}
