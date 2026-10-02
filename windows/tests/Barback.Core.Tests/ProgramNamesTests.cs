using Barback.Core;
namespace Barback.Core.Tests;

public class ProgramNamesTests
{
    private static string Suffix(int n) => n == 1 ? " (restored)" : $" (restored {n})";
    [Fact]
    public void FreeNamesAreKeptAndCollisionsGetNumberedSuffixes()
    {
        var used = new HashSet<string> { ProgramNames.Key("Web") };
        Assert.Equal("Api", ProgramNames.MakeUnique("Api", Suffix, used));
        Assert.Equal("Web (restored)", ProgramNames.MakeUnique("Web", Suffix, used));
        Assert.Equal("Web (restored 2)", ProgramNames.MakeUnique("Web", Suffix, used));
        Assert.Equal("WEB (restored 3)", ProgramNames.MakeUnique("WEB", Suffix, used));
    }
    [Fact]
    public void ComparisonUsesTheStoreKeyRules()
    {
        var used = new HashSet<string> { ProgramNames.Key("  ÀPI  ") };
        Assert.Equal("àpi (x)", ProgramNames.MakeUnique("àpi", n => " (x)", used));
        Assert.Equal(ProgramNames.Key("api"), new ProgramConfig { Name = "API" }.NameKey);
    }
}
