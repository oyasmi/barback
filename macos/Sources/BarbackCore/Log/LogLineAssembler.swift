import Foundation

/// Turns raw log bytes into display lines for the log viewers (design.md §4).
///
/// Reads land at arbitrary byte offsets: a read can stop in the middle of a line, or in the
/// middle of a multi-byte UTF-8 character. Decoding each read on its own used to split such a
/// line in two and turn a CJK character cut by the boundary into "��" on both sides. Only the
/// bytes up to the last newline are committed as lines here; the rest is carried into the next
/// read and is only ever *shown* as an unfinished line. Splitting at `\n` is always safe for
/// UTF-8 — 0x0A never occurs inside a multi-byte sequence.
public struct LogLineAssembler {
    /// A line that never ends (a progress bar without newlines, a binary blob) is committed
    /// once it reaches this size, so the carry cannot grow without bound.
    public static let maxLineBytes = 64 * 1024

    private var carry: [UInt8] = []

    public init() {}

    /// Appends bytes and returns the lines they completed, cleaned for display.
    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        carry.append(contentsOf: bytes)
        var lines: [String] = []
        if let lastNewline = carry.lastIndex(of: 0x0A) {
            for line in carry[..<lastNewline].split(separator: 0x0A, omittingEmptySubsequences: false) {
                lines.append(TerminalText.clean(String(decoding: line, as: UTF8.self)))
            }
            carry.removeSubrange(...lastNewline)
        }
        while carry.count > Self.maxLineBytes {
            var cut = Self.completeUTF8Length(carry[..<Self.maxLineBytes])
            if cut == 0 { cut = Self.maxLineBytes }
            lines.append(TerminalText.clean(String(decoding: carry[..<cut], as: UTF8.self)))
            carry.removeSubrange(..<cut)
        }
        return lines
    }

    /// The unfinished last line as it should be shown right now: cleaned, and without a
    /// trailing multi-byte character whose remaining bytes have not arrived yet.
    public var partial: String {
        guard !carry.isEmpty else { return "" }
        let complete = Self.completeUTF8Length(carry[...])
        return TerminalText.clean(String(decoding: carry[..<complete], as: UTF8.self))
    }

    /// Length of the longest prefix of `bytes` that does not end inside a UTF-8 sequence.
    /// Malformed input is left as is — the decoder turns it into U+FFFD.
    static func completeUTF8Length(_ bytes: ArraySlice<UInt8>) -> Int {
        var index = bytes.endIndex
        var scanned = 0
        while index > bytes.startIndex && scanned < 4 {
            index -= 1
            scanned += 1
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 { continue } // continuation byte: keep looking for the lead
            let needed: Int
            switch byte {
            case 0xF0...: needed = 4
            case 0xE0...: needed = 3
            case 0xC0...: needed = 2
            default: needed = 1
            }
            let available = bytes.endIndex - index
            return available >= needed ? bytes.count : index - bytes.startIndex
        }
        return bytes.count
    }
}

/// Makes one line of terminal output readable as plain text.
public enum TerminalText {
    /// Drops ANSI escape sequences (colours, cursor movement, window titles) and control
    /// characters, and resolves carriage returns the way a terminal would show the line in the
    /// end: `50%\r60%` reads as `60%`. A carriage return at the very end is just CRLF.
    public static func clean(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 0x09) || $0.value == 0x7F }) else {
            return line
        }
        let scalars = Array(line.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x1B {
                index = skipEscape(scalars, from: index + 1)
                continue
            }
            if value == 0x0D {
                if index + 1 < scalars.count { output.removeAll() }
            } else if value == 0x09 || (value >= 0x20 && value != 0x7F) {
                output.append(scalars[index])
            }
            index += 1
        }
        return String(output)
    }

    /// Returns the index just past the escape sequence whose ESC preceded `start`. An
    /// unterminated sequence swallows the rest of the line rather than leaking half of it.
    private static func skipEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        guard start < scalars.count else { return start }
        var index = start + 1
        switch scalars[start] {
        case "[":
            // CSI: parameter and intermediate bytes, then one final byte in 0x40–0x7E.
            while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
            return min(index + 1, scalars.count)
        case "]":
            // OSC: terminated by BEL or by ST (ESC \).
            while index < scalars.count {
                if scalars[index].value == 0x07 { return index + 1 }
                if scalars[index].value == 0x1B, index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
                index += 1
            }
            return scalars.count
        default:
            // Two-character escapes such as ESC 7 / ESC 8 / ESC (B.
            return index
        }
    }
}
