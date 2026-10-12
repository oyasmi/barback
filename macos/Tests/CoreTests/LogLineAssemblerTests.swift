import Foundation
import Testing
@testable import BarbackCore

struct LogLineAssemblerTests {
    @Test func lineSplitAcrossReadsStaysOneLine() {
        var assembler = LogLineAssembler()
        #expect(assembler.append(Array("hel".utf8)).isEmpty)
        #expect(assembler.partial == "hel")
        #expect(assembler.append(Array("lo\nwor".utf8)) == ["hello"])
        #expect(assembler.partial == "wor")
        #expect(assembler.append(Array("ld\n".utf8)) == ["world"])
        #expect(assembler.partial == "")
    }

    @Test func multiByteCharacterSplitAcrossReadsIsNotGarbled() {
        var assembler = LogLineAssembler()
        let bytes = Array("启动完成\n".utf8)
        // Cut inside the second character (each of these is three bytes).
        #expect(assembler.append(bytes[..<4]).isEmpty)
        #expect(assembler.partial == "启")
        #expect(assembler.append(bytes[4...]) == ["启动完成"])
    }

    @Test func emptyLinesAreKeptButNoTrailingBlankLineIsAdded() {
        var assembler = LogLineAssembler()
        #expect(assembler.append(Array("a\n\nb\n".utf8)) == ["a", "", "b"])
        #expect(assembler.partial == "")
    }

    @Test func endlessLineIsCommittedInBoundedPieces() {
        var assembler = LogLineAssembler()
        let lines = assembler.append(Array(repeating: UInt8(ascii: "x"), count: LogLineAssembler.maxLineBytes + 10))
        #expect(lines.count == 1)
        #expect(lines[0].utf8.count == LogLineAssembler.maxLineBytes)
        #expect(assembler.partial.utf8.count == 10)
    }

    @Test func completeUTF8LengthStopsBeforeAnUnfinishedSequence() {
        let bytes = Array("a好".utf8)
        #expect(LogLineAssembler.completeUTF8Length(bytes[...]) == 4)
        #expect(LogLineAssembler.completeUTF8Length(bytes[..<3]) == 1)
        #expect(LogLineAssembler.completeUTF8Length(bytes[..<1]) == 1)
    }
}

struct TerminalTextTests {
    @Test func stripsColourAndCursorSequences() {
        #expect(TerminalText.clean("\u{1B}[32mOK\u{1B}[0m done") == "OK done")
        #expect(TerminalText.clean("\u{1B}[2K\u{1B}[1Gready") == "ready")
        #expect(TerminalText.clean("\u{1B}]0;title\u{07}text") == "text")
        #expect(TerminalText.clean("\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
    }

    @Test func carriageReturnsResolveToTheFinalText() {
        #expect(TerminalText.clean("10%\r50%\r100%") == "100%")
        #expect(TerminalText.clean("windows line\r") == "windows line")
    }

    @Test func plainTextAndTabsAreUntouched() {
        #expect(TerminalText.clean("a\tb 中文") == "a\tb 中文")
        #expect(TerminalText.clean("bell\u{07}") == "bell")
    }

    @Test func unterminatedEscapeDoesNotLeakIntoTheLine() {
        #expect(TerminalText.clean("text\u{1B}[3") == "text")
    }
}
