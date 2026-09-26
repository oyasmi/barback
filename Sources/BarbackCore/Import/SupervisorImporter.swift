import Foundation

public struct ImportUnmappedField: Sendable, Equatable {
    public let key: String
    public let reason: String
}

public struct ImportPreview: Sendable, Equatable {
    public var program: Program
    public var unmapped: [ImportUnmappedField]
    public var sourceSectionName: String
}

/// Parses pasted supervisor INI text (`[program:x]` sections) into Barback `Program`
/// drafts, per design.md §7. Purely textual — never touches supervisor's own files.
public enum SupervisorImporter {
    public static func parse(_ text: String) -> [ImportPreview] {
        let sections = splitSections(text)
        return sections.compactMap { name, kv in
            guard name.hasPrefix("program:") else { return nil }
            let programName = String(name.dropFirst("program:".count))
            return buildPreview(name: programName, sectionName: name, kv: kv)
        }
    }

    private static func splitSections(_ text: String) -> [(String, [String: String])] {
        var sections: [(String, [String: String])] = []
        var currentName: String?
        var currentKV: [String: String] = [:]
        var lastKey: String?

        func flush() {
            if let name = currentName {
                sections.append((name, currentKV))
            }
            currentName = nil
            currentKV = [:]
            lastKey = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                flush()
                currentName = String(trimmed.dropFirst().dropLast())
                continue
            }
            if line.first == " " || line.first == "\t", let lastKey, currentName != nil {
                // continuation line (supervisor allows indented continuations)
                currentKV[lastKey, default: ""] += "\n" + trimmed
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            currentKV[key] = value
            lastKey = key
        }
        flush()
        return sections
    }

    private static func buildPreview(name: String, sectionName: String, kv: [String: String]) -> ImportPreview {
        var unmapped: [ImportUnmappedField] = []
        var command = kv["command"] ?? ""
        var useShell = false
        if command.hasPrefix("sh -c ") || command.hasPrefix("/bin/sh -c ") {
            useShell = true
            if let range = command.range(of: "-c ") {
                command = String(command[range.upperBound...])
                command = stripMatchingQuotes(command)
            }
        }

        var env: [String: EnvVar] = [:]
        if let environment = kv["environment"] {
            env = parseEnvironment(environment)
        }

        let autorestartRaw = kv["autorestart"]?.lowercased()
        let autorestart: AutoRestartPolicy
        switch autorestartRaw {
        case "true": autorestart = .always
        case "false": autorestart = .never
        case "unexpected", nil: autorestart = .unexpected
        default: autorestart = .unexpected
        }

        let exitCodes = (kv["exitcodes"] ?? "0").split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        // supervisor's own semantics (https://supervisord.org/configuration.html#program-x-section-values):
        // `AUTO` means "let us pick a path" — Barback's equivalent is simply not setting an
        // explicit path, so the program's default `<name>.out.log` applies. `NONE` means
        // "don't create a log file at all", which Barback has no first-class "discard" target
        // for — mapping both to the same nil used to silently turn a deliberate "discard this
        // program's output" into "write it to the default path" instead (R12).
        var logPath: String?
        var logStderrPath: String?
        let mergeStderr = (kv["redirect_stderr"]?.lowercased() == "true")
        if let stdout = kv["stdout_logfile"] {
            let upper = stdout.uppercased()
            if upper == "NONE" {
                logPath = "/dev/null"
            } else if upper != "AUTO" {
                logPath = stdout
            }
        }
        if let stderr = kv["stderr_logfile"] {
            let upper = stderr.uppercased()
            if mergeStderr {
                // redirect_stderr already merges; explicit stderr path becomes moot.
            } else if upper == "NONE" {
                logStderrPath = "/dev/null"
            } else if upper != "AUTO" {
                logStderrPath = stderr
            }
        }

        var program = Program(
            name: sanitizeName(name),
            kind: .service,
            command: command,
            useShell: useShell,
            directory: kv["directory"],
            environment: env,
            priority: kv["priority"].flatMap(Int.init) ?? 100,
            autostart: false, // design.md §7: always forced off on import
            autorestart: autorestart,
            exitCodes: exitCodes.isEmpty ? [0] : exitCodes,
            // supervisor defaults startsecs to 1s, not Barback's own default of 5s — imported
            // programs must keep supervisor's meaning when the key is absent (design.md §1
            // constraint #3, "同名字段必须同义"); Barback's own "new service" path still uses 5.
            startSeconds: kv["startsecs"].flatMap(Int.init) ?? 1,
            startRetries: kv["startretries"].flatMap(Int.init) ?? 3,
            stopSignal: kv["stopsignal"] ?? "TERM",
            stopWaitSeconds: kv["stopwaitsecs"].flatMap(Int.init) ?? 10,
            // supervisor defaults both to false; Barback defaults new programs to true (signal
            // the whole process group — the safer choice for a desktop tool stopping a command
            // that may have spawned children). Imported programs keep that Barback default when
            // the key is absent, but respect an explicit `true`/`false` from the INI either way.
            stopAsGroup: kv["stopasgroup"].map { $0.lowercased() == "true" } ?? true,
            killAsGroup: kv["killasgroup"].map { $0.lowercased() == "true" } ?? true,
            logPath: logPath,
            logMergeStderr: mergeStderr,
            logStderrPath: logStderrPath,
            logMaxBytes: parseByteSize(kv["stdout_logfile_maxbytes"]) ?? 10_485_760,
            logBackups: kv["stdout_logfile_backups"].flatMap(Int.init) ?? 3
        )
        program.notes = "从 supervisor 导入自 [\(sectionName)]"

        let unmappedKeys = ["user", "numprocs", "process_name", "serverurl", "umask", "stopasgroup", "killasgroup"]
        let reasons: [String: String] = [
            "user": "用户级运行，不支持切换用户",
            "numprocs": "不支持多实例",
            "process_name": "不支持多实例模板名",
            "serverurl": "无 RPC 接口",
            "umask": "暂不支持自定义 umask"
        ]
        for key in unmappedKeys {
            guard kv[key] != nil else { continue }
            if key == "stopasgroup" || key == "killasgroup" { continue } // mapped above
            unmapped.append(ImportUnmappedField(key: key, reason: reasons[key] ?? "不支持"))
        }

        return ImportPreview(program: program, unmapped: unmapped, sourceSectionName: sectionName)
    }

    // `CharacterSet.alphanumerics` is Unicode-aware (it passes accented letters, CJK, etc.)
    // while `Program.namePattern` only ever accepts `[A-Za-z0-9._-]` — an INI section like
    // `[program:服务]` used to sail straight through this filter and only then fail the name
    // regex it was supposed to already satisfy (R12).
    private static let allowedNameCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func sanitizeName(_ name: String) -> String {
        let filtered = name.unicodeScalars.filter { allowedNameCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(filtered))
        return result.isEmpty ? "imported" : String(result.prefix(64))
    }

    private static func stripMatchingQuotes(_ s: String) -> String {
        var s = s
        if (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Parses supervisor's quoted, comma-separated `KEY="val",KEY2="val2"` environment syntax.
    private static func parseEnvironment(_ raw: String) -> [String: EnvVar] {
        var result: [String: EnvVar] = [:]
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 }
            var key = ""
            while i < chars.count, chars[i] != "=" { key.append(chars[i]); i += 1 }
            guard i < chars.count else { break }
            i += 1 // skip '='
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" { value.append(chars[i]); i += 1 }
                i += 1
            } else {
                while i < chars.count, chars[i] != "," { value.append(chars[i]); i += 1 }
            }
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty {
                result[trimmedKey] = EnvVar(value: value)
            }
        }
        return result
    }

    private static func parseByteSize(_ raw: String?) -> Int64? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces).uppercased(), !s.isEmpty else { return nil }
        var multiplier: Int64 = 1
        if s.hasSuffix("KB") { multiplier = 1024; s.removeLast(2) }
        else if s.hasSuffix("MB") { multiplier = 1024 * 1024; s.removeLast(2) }
        else if s.hasSuffix("GB") { multiplier = 1024 * 1024 * 1024; s.removeLast(2) }
        guard let value = Int64(s.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        // `value * multiplier` on a plain `Int64` traps on overflow — a pasted
        // `stdout_logfile_maxbytes=9223372036854775807GB` used to crash the whole import
        // instead of just failing to parse that one field (R12).
        let (result, overflowed) = value.multipliedReportingOverflow(by: multiplier)
        return overflowed ? nil : result
    }
}
