using Barback.Core;
namespace Barback.Core.Tests;

public class AppLogTests
{
    private static string Temp() => Path.Combine(Path.GetTempPath(), "barback-applog-" + Guid.NewGuid());
    [Fact]
    public void LinesCarryTimestampLevelCategoryAndExceptionSummary()
    {
        var dir = Temp();
        try
        {
            var log = new AppLog(dir); Exception? thrown = null;
            try { throw new InvalidOperationException("boom\nsecond line"); } catch (Exception ex) { thrown = ex; }
            log.Write(AppLogLevel.Error, "supervisor", "request failed\r\nagain", thrown);
            var lines = File.ReadAllLines(Path.Combine(dir, "barback.log"));
            Assert.Matches(@"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z  ERROR    supervisor  request failed again  \[InvalidOperationException: boom second line\]$", lines[0]);
            Assert.All(lines.Skip(1), l => Assert.StartsWith("    ", l));
        }
        finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }
    [Fact]
    public void RotationKeepsConfiguredFileCountAndSizeBound()
    {
        var dir = Temp();
        try
        {
            var log = new AppLog(dir, maxBytes: 2000, files: 3);
            for (int i = 0; i < 200; i++) log.Info("test", "line " + i + new string('x', 50));
            var files = Directory.GetFiles(dir).Select(f => Path.GetFileName(f)!).Order().ToArray();
            Assert.Equal(["barback.log", "barback.log.1", "barback.log.2"], files);
            Assert.All(Directory.GetFiles(dir), f => Assert.True(new FileInfo(f).Length <= 2000));
            Assert.Contains("line 199", File.ReadAllText(Path.Combine(dir, "barback.log")));
        }
        finally { Directory.Delete(dir, true); }
    }
    [Fact]
    public async Task ConcurrentWritersLoseNoLinesAndNeverThrow()
    {
        var dir = Temp();
        try
        {
            var log = new AppLog(dir, maxBytes: 50L * 1024 * 1024);
            await Task.WhenAll(Enumerable.Range(0, 8).Select(t => Task.Run(() => { for (int i = 0; i < 250; i++) log.Info("t" + t, "n" + i); })));
            Assert.Equal(2000, File.ReadAllLines(Path.Combine(dir, "barback.log")).Length);
        }
        finally { Directory.Delete(dir, true); }
    }
    [Fact]
    public void UnwritableDirectoryIsSwallowed()
    {
        var file = Path.Combine(Path.GetTempPath(), "barback-applog-file-" + Guid.NewGuid()); File.WriteAllText(file, "");
        try { new AppLog(Path.Combine(file, "nested")).Error("test", "cannot be written", new IOException("x")); } // a path below a file can never be created
        finally { File.Delete(file); }
    }
}
