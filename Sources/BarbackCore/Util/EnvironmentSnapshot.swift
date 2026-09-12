import Foundation

/// Captures the user's login-shell environment so autostarted (login-item) processes see
/// the same `PATH` etc. as a Terminal session — the classic "works in Terminal, not at
/// login" macOS gotcha (design.md §5.3).
public enum EnvironmentSnapshot {
    private static let volatileKeys: Set<String> = ["_", "PWD", "SHLVL", "OLDPWD"]

    public static func capture(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> [String: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-i", "-c", "export -p"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return ProcessInfo.processInfo.environment
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return ProcessInfo.processInfo.environment
        }
        return parseExportOutput(output)
    }

    /// Parses `export -p` / `export FOO="bar"` lines, filtering volatile shell-only keys.
    static func parseExportOutput(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export ") || trimmed.hasPrefix("declare -x ") else { continue }
            if trimmed.hasPrefix("export ") { trimmed.removeFirst("export ".count) }
            if trimmed.hasPrefix("declare -x ") { trimmed.removeFirst("declare -x ".count) }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq])
            guard !key.hasPrefix("TERM"), !volatileKeys.contains(key) else { continue }
            var value = String(trimmed[trimmed.index(after: eq)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            result[key] = value
        }
        return result
    }
}
