import Foundation

/// Captures the user's login-shell environment so autostarted (login-item) processes see
/// the same `PATH` etc. as a Terminal session — the classic "works in Terminal, not at
/// login" macOS gotcha (design.md §5.3).
public enum EnvironmentSnapshot {
    private static let volatileKeys: Set<String> = ["_", "PWD", "SHLVL", "OLDPWD"]

    /// This runs on `Supervisor.bootstrap()`'s very first line, on the one serial queue every
    /// managed process depends on — so it used to be able to wedge the whole app before a
    /// single service was ever started, in two separate ways: `standardError` was a `Pipe()`
    /// nobody ever read, so a `.zshrc` that writes so much as a version-manager warning to
    /// stderr fills the 64KB pipe buffer and blocks the child on `write()` forever, which
    /// means stdout's `readDataToEndOfFile()` never sees EOF either; and `-i` (interactive)
    /// pulls in prompt/plugin machinery that can itself wait on a terminal that isn't there
    /// (design.md §5.3, ex-F23). Discarding stderr, dropping `-i`, and bounding the whole
    /// thing with a timeout turns "hangs forever" into "falls back to `ProcessInfo` after 5s".
    public static func capture(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> [String: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-c", "export -p"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return ProcessInfo.processInfo.environment
        }
        // A plain `Box` — `Data` itself is `Sendable`, but a `var` captured by a `@Sendable`
        // closure isn't, since two threads could see it change out from under them. There's
        // no actual race here (the wait below always happens-before the read), so it's boxed
        // rather than routed through an actor for a one-shot handoff.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + 5) == .success else {
            task.terminate()
            return ProcessInfo.processInfo.environment
        }
        guard let output = String(data: box.data, encoding: .utf8) else {
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
