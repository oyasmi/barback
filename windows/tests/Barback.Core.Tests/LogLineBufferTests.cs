using System.Text;
using Barback.Core;
namespace Barback.Core.Tests;

public class LogLineBufferTests
{
    [Fact]
    public void LfAndCrlfFinishLinesAndTheTailStaysPartial()
    {
        var buffer = new LogLineBuffer(); var delta = buffer.Append("one\r\ntwo\nthr");
        Assert.Equal(["one", "two"], delta.Added); Assert.Equal("thr", delta.Partial); Assert.Equal(0, delta.RemovedFromStart);
        delta = buffer.Append("ee\n"); Assert.Equal(["three"], delta.Added); Assert.Null(delta.Partial);
    }
    [Fact]
    public void CrlfSplitAcrossAppendsIsNotAnOverwrite()
    {
        var buffer = new LogLineBuffer(); buffer.Append("keep\r"); var delta = buffer.Append("\nnext\n");
        Assert.Equal(["keep", "next"], delta.Added);
    }
    [Fact]
    public void LoneCarriageReturnOverwritesTheUnfinishedLine()
    {
        var buffer = new LogLineBuffer(); var delta = buffer.Append("10%\r50%\r100%");
        Assert.Empty(delta.Added); Assert.Equal("100%", delta.Partial);
        Assert.Equal(["100%"], buffer.Append("\n").Added);
        buffer.Append("a\r"); Assert.Equal("a", buffer.Partial); // the rewind is only applied once more text arrives
        Assert.Equal("b", buffer.Append("b").Partial);
    }
    [Fact]
    public void VeryLongLinesAreSplitIntoBoundedChunks()
    {
        var buffer = new LogLineBuffer(); var delta = buffer.Append(new string('x', 150_000) + "\n");
        Assert.Equal([65536, 65536, 18928], delta.Added.Select(l => l.Length).ToArray());
        // Without any newline the unfinished text must not grow without bound.
        var endless = new LogLineBuffer(); endless.Append(new string('y', 200_000));
        Assert.Equal(3, endless.Count); Assert.Equal(200_000 - 3 * 65536, endless.Partial!.Length);
    }
    [Fact]
    public void ChunkingNeverSplitsASurrogatePair()
    {
        var text = new string('a', LogLineBuffer.MaxLineChars - 1) + "😀tail\n"; var buffer = new LogLineBuffer(); var lines = buffer.Append(text).Added;
        Assert.All(lines, l => Assert.False(l.Length > 0 && char.IsHighSurrogate(l[^1])));
        Assert.Equal(text.TrimEnd('\n'), string.Concat(lines));
    }
    [Fact]
    public void EvictionRemovesAtLeastTenPercentInOneBlock()
    {
        var buffer = new LogLineBuffer(maxLines: 100); buffer.Append(string.Concat(Enumerable.Range(0, 100).Select(i => $"l{i}\n")));
        Assert.Equal(100, buffer.Count); var delta = buffer.Append("l100\n");
        Assert.Equal(["l100"], delta.Added); Assert.Equal(11, delta.RemovedFromStart); Assert.Equal(90, buffer.Count); Assert.Equal("l11", buffer.Lines[0]);
        Assert.Equal(101, buffer.TotalAdded); Assert.Equal(11, buffer.TotalRemoved);
    }
    [Fact]
    public void EvictionByCharactersAndOverflowingASingleAppend()
    {
        var chars = new LogLineBuffer(maxLines: 1000, maxChars: 100); chars.Append(string.Concat(Enumerable.Repeat(new string('z', 9) + "\n", 20)));
        Assert.True(chars.Lines.Sum(l => l.Length) <= 90);
        var small = new LogLineBuffer(maxLines: 10); var delta = small.Append(string.Concat(Enumerable.Range(0, 25).Select(i => $"n{i}\n")));
        Assert.Equal(0, delta.RemovedFromStart); Assert.True(small.Count <= 9); Assert.Equal("n24", small.Lines[^1]);
        Assert.Equal(small.Lines, delta.Added); // evicted new lines are not reported as added
    }
    [Fact]
    public void ViewReconciliationCountersAreConsistent()
    {
        var buffer = new LogLineBuffer(maxLines: 20); var mirror = new List<string>(); long added = 0, removed = 0;
        for (int round = 0; round < 30; round++)
        {
            buffer.Append(string.Concat(Enumerable.Range(0, 7).Select(i => $"r{round}-{i}\n")));
            int remove = (int)Math.Min(buffer.TotalRemoved - removed, mirror.Count); long fresh = Math.Min(buffer.TotalAdded - added, buffer.Count);
            mirror.RemoveRange(0, remove); mirror.AddRange(buffer.Lines.Skip(buffer.Count - (int)fresh)); added = buffer.TotalAdded; removed = buffer.TotalRemoved;
            Assert.Equal(buffer.Lines, mirror);
        }
    }
    [Theory]
    [InlineData("\u001b[32mgreen\u001b[0m text", "green text")]
    [InlineData("\u001b[1;31;40mred\u001b[m", "red")]
    [InlineData("\u001b]0;window title\u0007visible", "visible")]
    [InlineData("\u001b]8;;http://x\u001b\\link\u001b]8;;\u001b\\", "link")]
    [InlineData("\u001b(Bplain", "plain")]
    [InlineData("a\u001bcb", "ab")]
    [InlineData("tab\tkept\u0007\u0001\u0000x", "tab\tkeptx")]
    [InlineData("tail\u001b[3", "tail")]
    public void AnsiAndControlCharactersAreStrippedFromFinishedLines(string raw, string expected) =>
        Assert.Equal([expected], new LogLineBuffer().Append(raw + "\n").Added);
    [Fact]
    public void EscapeSequenceSplitAcrossAppendsIsNotTruncated()
    {
        var buffer = new LogLineBuffer(); var first = buffer.Append("ok \u001b[3"); Assert.Equal("ok", first.Partial?.TrimEnd());
        var second = buffer.Append("2mgreen\u001b[0m\n"); Assert.Equal(["ok green"], second.Added);
        var osc = new LogLineBuffer(); osc.Append("\u001b]0;ti"); Assert.Equal(["x"], osc.Append("tle\u0007x\n").Added);
    }
    [Fact]
    public void FlushAndMarkerFinishTheUnfinishedLine()
    {
        var buffer = new LogLineBuffer(); buffer.Append("crashed mid-line");
        var delta = buffer.AppendMarker("──── new run ────");
        Assert.Equal(["crashed mid-line", "──── new run ────"], delta.Added); Assert.Null(delta.Partial);
        Assert.Empty(buffer.Flush().Added);
    }
    [Theory]
    [InlineData(65001)]
    [InlineData(1200)]
    public void DecoderPlusBufferHandlesCharactersSplitAcrossReads(int codePage)
    {
        var encoding = Encoding.GetEncoding(codePage); var text = "你好，世界 😀\nline2\n"; var bytes = encoding.GetBytes(text);
        var decoder = new IncrementalLogDecoder(codePage); var buffer = new LogLineBuffer();
        for (int i = 0; i < bytes.Length; i += 3) buffer.Append(decoder.Decode(bytes.AsSpan(i, Math.Min(3, bytes.Length - i))));
        Assert.Equal(["你好，世界 😀", "line2"], buffer.Lines);
        Assert.Equal("a\u001bb", new IncrementalLogDecoder(65001).Decode("a\u001bb"u8)); // ESC is no longer rewritten to a visible symbol
    }
}
