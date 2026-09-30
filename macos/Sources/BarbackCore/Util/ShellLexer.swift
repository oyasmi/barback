import Foundation

public enum ShellLexerError: Error, LocalizedError, Equatable {
    case unterminatedQuote
    case trailingBackslash

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote: return "未闭合的引号"
        case .trailingBackslash: return "命令以反斜杠结尾"
        }
    }
}

/// Minimal POSIX-ish shell word splitter used when `useShell == false`.
/// Supports single quotes, double quotes (with backslash-escaping of \" \\ \$ \`),
/// unquoted backslash-escaping, and whitespace-separated words.
public enum ShellLexer {
    public static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        let chars = Array(input)
        var i = 0

        enum Quote { case none, single, double }
        var quote: Quote = .none

        func flush() {
            if hasCurrent {
                tokens.append(current)
                current = ""
                hasCurrent = false
            }
        }

        while i < chars.count {
            let c = chars[i]
            switch quote {
            case .none:
                if c == " " || c == "\t" || c == "\n" {
                    flush()
                } else if c == "'" {
                    quote = .single
                    hasCurrent = true
                } else if c == "\"" {
                    quote = .double
                    hasCurrent = true
                } else if c == "\\" {
                    guard i + 1 < chars.count else { throw ShellLexerError.trailingBackslash }
                    current.append(chars[i + 1])
                    hasCurrent = true
                    i += 1
                } else {
                    current.append(c)
                    hasCurrent = true
                }
            case .single:
                if c == "'" {
                    quote = .none
                } else {
                    current.append(c)
                }
            case .double:
                if c == "\"" {
                    quote = .none
                } else if c == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                    current.append(chars[i + 1])
                    i += 1
                } else {
                    current.append(c)
                }
            }
            i += 1
        }
        if quote != .none { throw ShellLexerError.unterminatedQuote }
        flush()
        return tokens
    }
}
