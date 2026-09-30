using System.Text;
using Barback.Core;
namespace Barback.Core.Tests;

public class InputTests
{
    [Theory]
    [InlineData("", "\"\"")]
    [InlineData("simple", "simple")]
    [InlineData("hello world", "\"hello world\"")]
    [InlineData("a\"b", "\"a\\\"b\"")]
    public void QuoteCrtCases(string raw, string quoted) => Assert.Equal(quoted, WindowsCommandLine.Quote(raw));
    [Fact] public void TrailingSlashInQuotedArgument() => Assert.Equal("\"space " + new string('\\', 2) + "\"", WindowsCommandLine.Quote("space " + '\\'));
    [Fact]
    public void DirectMetacharactersAreNotShellExpanded()
    {
        var spec = new LaunchSpec { Executable = "C:\\tools\\node.exe", Arguments = ["|", ">", "$x", "%X%"] };
        var built = WindowsCommandLine.Build(spec, "C:\\Windows\\System32"); Assert.EndsWith(" | > $x %X%", built.CommandLine); Assert.Equal(spec.Executable, built.Executable);
    }
    [Fact]
    public void PowerShellNeverLoadsProfileOrBypassesPolicy()
    {
        var (exe, line) = WindowsCommandLine.Build(new() { Mode = ExecutionMode.PowerShellText, Executable = "powershell.exe", ScriptText = "'中文'" }, "system");
        Assert.Contains("-NoProfile -NonInteractive -EncodedCommand", line); Assert.DoesNotContain("Bypass", line); Assert.EndsWith(Convert.ToBase64String(Encoding.Unicode.GetBytes("'中文'")), line);
    }
    [Fact]
    public void EnvironmentKeepsLiteralValuesAndRejectsCaseConflict()
    {
        var raw = "Path=a\n\nPATH=b\nTOKEN=literal $x %X%  \n-OLD"; var parsed = EnvironmentDraft.Parse(raw);
        Assert.Single(parsed.Errors); Assert.Equal(3, parsed.Errors[0].Line); Assert.Equal("literal $x %X%  ", parsed.Entries.Single(e => e.Key == "TOKEN").Value);
        Assert.True(parsed.Entries.Single(e => e.Key == "OLD").Remove);
    }
    [Fact]
    public void LayeredEnvironmentHonorsRemoveAndEmpty()
    {
        var result = EnvironmentDraft.Merge(new Dictionary<string, string> { ["Path"] = "base", ["OLD"] = "old" }, [new("PATH", "app")], [new("Path", "program"), new("OLD", null, Remove: true), new("EMPTY", "")]);
        Assert.Equal("program", result["PATH"]); Assert.False(result.ContainsKey("OLD")); Assert.Equal("", result["EMPTY"]);
    }
    [Fact]
    public void ImportIsDisabledAndFlagsDangerousUnsupportedFields()
    {
        var preview = SupervisorImporter.Preview("[include]\nfiles=/tmp/malicious\n[program:web]\ncommand=/bin/sh -c evil\nautostart=true\nuser=root\nprocess_name=%(program_name)s\n[program:web]\ncommand=x");
        Assert.Equal(2, preview.Count); Assert.All(preview, d => { Assert.False(d.Config.Enabled); Assert.False(d.Config.Policy.Autostart); Assert.Equal(1, d.Config.Policy.StartSeconds); });
        Assert.Contains(preview[0].Issues, i => i.Field == "user" && i.Status == "Unsupported"); Assert.Contains(preview[1].Issues, i => i.Field == "name");
    }
    [Fact]
    public void IncrementalDecoderKeepsSplitUtf8AndUtf16()
    {
        foreach (var code in new[] { 65001, 1200, 936 })
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance); var bytes = Encoding.GetEncoding(code).GetBytes("中文abc"); var decoder = new IncrementalLogDecoder(code); var result = "";
            foreach (var b in bytes) result += decoder.Decode([b]); Assert.Equal("中文abc", result);
        }
    }
}
