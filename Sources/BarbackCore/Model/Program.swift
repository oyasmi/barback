import Foundation

public enum ProgramKind: String, Codable, Sendable {
    case service
    case oneshot
}

public enum AutoRestartPolicy: String, Codable, Sendable {
    case never
    case unexpected
    case always
}

public enum LogRotatePolicy: String, Codable, Sendable {
    case size
    case onRestart
    case never
}

public struct EnvVar: Codable, Sendable, Equatable {
    public var value: String
    public var sensitive: Bool

    public init(value: String, sensitive: Bool = false) {
        self.value = value
        self.sensitive = sensitive
    }
}

/// A managed object: either a long-running service or a one-shot command.
/// Mirrors the `program` table (design.md §5.2).
public struct Program: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var kind: ProgramKind
    public var enabled: Bool
    public var command: String
    public var useShell: Bool
    public var directory: String?
    public var environment: [String: EnvVar]
    public var groupName: String?
    public var priority: Int
    public var notes: String?

    // service-only
    public var autostart: Bool
    public var autorestart: AutoRestartPolicy
    public var exitCodes: [Int32]
    public var startSeconds: Int
    public var startRetries: Int
    public var backoffBase: Double
    public var backoffMax: Double
    public var stormWindowSec: Int
    public var stormMaxRestarts: Int

    // oneshot-only
    public var timeoutSeconds: Int
    public var confirmBeforeRun: Bool
    public var historyLimit: Int

    // stop (shared)
    public var stopSignal: String
    public var stopWaitSeconds: Int
    public var stopAsGroup: Bool
    public var killAsGroup: Bool

    // logging
    public var logPath: String?
    public var logMergeStderr: Bool
    public var logStderrPath: String?
    public var logMaxBytes: Int64
    public var logBackups: Int
    public var logRotatePolicy: LogRotatePolicy

    /// Lifetime execution count, maintained by `Store.incrementRunTotal` — not editable via
    /// the config form, and deliberately excluded from `Store.updateProgram`'s column list so
    /// saving a stale draft can never roll it back (design.md §3.4).
    public var runTotal: Int

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64 = 0,
        name: String,
        kind: ProgramKind,
        enabled: Bool = true,
        command: String,
        useShell: Bool = false,
        directory: String? = nil,
        environment: [String: EnvVar] = [:],
        groupName: String? = nil,
        priority: Int = 100,
        notes: String? = nil,
        autostart: Bool = true,
        autorestart: AutoRestartPolicy = .unexpected,
        exitCodes: [Int32] = [0],
        startSeconds: Int = 5,
        startRetries: Int = 3,
        backoffBase: Double = 1.0,
        backoffMax: Double = 60.0,
        stormWindowSec: Int = 600,
        stormMaxRestarts: Int = 10,
        timeoutSeconds: Int = 0,
        confirmBeforeRun: Bool = false,
        historyLimit: Int = 50,
        stopSignal: String = "TERM",
        stopWaitSeconds: Int = 10,
        stopAsGroup: Bool = true,
        killAsGroup: Bool = true,
        logPath: String? = nil,
        logMergeStderr: Bool = true,
        logStderrPath: String? = nil,
        logMaxBytes: Int64 = 10_485_760,
        logBackups: Int = 3,
        logRotatePolicy: LogRotatePolicy = .size,
        runTotal: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.command = command
        self.useShell = useShell
        self.directory = directory
        self.environment = environment
        self.groupName = groupName
        self.priority = priority
        self.notes = notes
        self.autostart = autostart
        self.autorestart = autorestart
        self.exitCodes = exitCodes
        self.startSeconds = startSeconds
        self.startRetries = startRetries
        self.backoffBase = backoffBase
        self.backoffMax = backoffMax
        self.stormWindowSec = stormWindowSec
        self.stormMaxRestarts = stormMaxRestarts
        self.timeoutSeconds = timeoutSeconds
        self.confirmBeforeRun = confirmBeforeRun
        self.historyLimit = historyLimit
        self.stopSignal = stopSignal
        self.stopWaitSeconds = stopWaitSeconds
        self.stopAsGroup = stopAsGroup
        self.killAsGroup = killAsGroup
        self.logPath = logPath
        self.logMergeStderr = logMergeStderr
        self.logStderrPath = logStderrPath
        self.logMaxBytes = logMaxBytes
        self.logBackups = logBackups
        self.logRotatePolicy = logRotatePolicy
        self.runTotal = runTotal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The fields that only take effect for an *already-running* instance after a restart —
    /// the rest (autostart/autorestart/priority/group/notes/rotation params, per CFG-5) apply
    /// immediately. The config window and the status panel both need this same distinction
    /// (one to warn before save, one to warn after), so it lives here as the single source of
    /// truth rather than as two separately-maintained field lists.
    public static func runtimeFieldsDiffer(_ a: Program, _ b: Program) -> Bool {
        a.command != b.command || a.useShell != b.useShell || a.directory != b.directory ||
        a.environment != b.environment || a.logPath != b.logPath || a.logStderrPath != b.logStderrPath ||
        a.stopSignal != b.stopSignal || a.stopWaitSeconds != b.stopWaitSeconds || a.timeoutSeconds != b.timeoutSeconds
    }

    /// The built-in defaults for every field that isn't identity (name/kind/command) —
    /// what an advanced field reads as "unset". Used to grey out untouched fields, badge
    /// changed ones, and drive per-section "恢复默认值".
    public static func defaults(name: String, kind: ProgramKind, command: String) -> Program {
        Program(name: name, kind: kind, command: command)
    }
}

/// Validation for a Program, per CFG-4.
public enum ProgramValidationError: Error, LocalizedError, Sendable, Equatable {
    case invalidName
    case duplicateName
    case emptyCommand
    case executableNotFound(String)
    case directoryNotFound(String)
    case invalidLogPath(String)
    case invalidNumber(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "名称必须是 1-64 位的字母、数字、`.`、`_`、`-`"
        case .duplicateName: return "名称已存在"
        case .emptyCommand: return "命令不能为空"
        case .executableNotFound(let p): return "找不到可执行文件：\(p)"
        case .directoryNotFound(let p): return "工作目录不存在：\(p)"
        case .invalidLogPath(let p): return "日志路径无效：\(p)"
        case .invalidNumber(let field): return "数值字段非法：\(field)"
        }
    }
}

public enum ProgramValidator {
    public static let namePattern = "^[A-Za-z0-9._-]{1,64}$"

    public static func validateName(_ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: namePattern) else { return false }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Full validation. `existingNames` should exclude the program's own current name when
    /// editing. `pathEnv` should be the same `PATH` the program will actually be spawned
    /// with (`Supervisor.mergedEnvironment`'s value, not this process's own environment) —
    /// otherwise "找不到可执行文件" can disagree with what `posix_spawn` itself finds,
    /// in either direction (ex-F41).
    public static func validate(_ program: Program, existingNames: Set<String>, pathEnv: String? = nil) -> [ProgramValidationError] {
        var errors: [ProgramValidationError] = []
        if !validateName(program.name) {
            errors.append(.invalidName)
        } else if existingNames.contains(program.name) {
            errors.append(.duplicateName)
        }
        let trimmedCommand = program.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommand.isEmpty {
            errors.append(.emptyCommand)
        } else if !program.useShell {
            if let tokens = try? ShellLexer.tokenize(program.command), let first = tokens.first {
                let resolved = PathUtil.resolveExecutable(first, directory: program.directory, pathEnv: pathEnv)
                if resolved == nil {
                    errors.append(.executableNotFound(first))
                }
            }
        }
        if let dir = program.directory {
            let expanded = PathUtil.expandTilde(dir)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) || !isDir.boolValue {
                errors.append(.directoryNotFound(dir))
            }
        }
        if let logPath = program.logPath, let error = validateLogPath(logPath) {
            errors.append(error)
        }
        if !program.logMergeStderr, let logStderrPath = program.logStderrPath, let error = validateLogPath(logStderrPath) {
            errors.append(error)
        }
        if program.startSeconds < 0 { errors.append(.invalidNumber("startSeconds")) }
        if program.startRetries < 0 { errors.append(.invalidNumber("startRetries")) }
        if program.backoffBase <= 0 { errors.append(.invalidNumber("backoffBase")) }
        if program.backoffMax < program.backoffBase { errors.append(.invalidNumber("backoffMax")) }
        // A `stormMaxRestarts` of 0 makes `isStorming` true (`count >= 0`) on the very first
        // unexpected exit — one FATAL and no more retries, no matter how generous
        // `startRetries` is. A `stormWindowSec` of 0 has the opposite effect: every restart
        // timestamp falls outside a zero-width window, so storm protection never fires at all
        // (ex-F40, both reachable by simply clearing an `IntField`).
        if program.stormWindowSec < 1 { errors.append(.invalidNumber("stormWindowSec")) }
        if program.stormMaxRestarts < 1 { errors.append(.invalidNumber("stormMaxRestarts")) }
        if program.stopWaitSeconds < 0 { errors.append(.invalidNumber("stopWaitSeconds")) }
        if program.timeoutSeconds < 0 { errors.append(.invalidNumber("timeoutSeconds")) }
        if program.historyLimit < 1 { errors.append(.invalidNumber("historyLimit")) }
        if program.logMaxBytes < 0 { errors.append(.invalidNumber("logMaxBytes")) }
        if program.logBackups < 0 { errors.append(.invalidNumber("logBackups")) }
        return errors
    }

    /// Rejects only what can never be opened as a log file — a path that already exists as a
    /// directory, or whose parent exists but isn't one. A parent that doesn't exist *yet* is
    /// fine: `LogManager.openServiceLogs` creates it lazily, the same way it always has for
    /// the default (non-explicit) log path (ex-F33).
    private static func validateLogPath(_ raw: String) -> ProgramValidationError? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidLogPath(raw) }
        let expanded = PathUtil.expandTilde(trimmed)
        guard expanded.hasPrefix("/") else { return .invalidLogPath(raw) }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return .invalidLogPath(raw)
        }
        let parent = (expanded as NSString).deletingLastPathComponent
        if !parent.isEmpty, fm.fileExists(atPath: parent, isDirectory: &isDir), !isDir.boolValue {
            return .invalidLogPath(raw)
        }
        return nil
    }
}
