import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct SpawnedProcess: Sendable, Equatable {
    public let pid: Int32
    public let pgid: Int32
    public let startTime: Double
}

public enum ProcessHostError: Error, LocalizedError, Equatable {
    case posixSpawnFailed(Int32)
    case cannotOpenLog(String)
    case invalidCommand

    public var errorDescription: String? {
        switch self {
        case .posixSpawnFailed(let code): return "posix_spawn 失败：\(String(cString: strerror(code)))"
        case .cannotOpenLog(let path): return "无法打开日志文件：\(path)"
        case .invalidCommand: return "命令无法解析"
        }
    }
}

/// Wraps `posix_spawn` with SETSID so managed processes become session leaders
/// (design.md §3.1, D-4). Never uses `fork()` directly to avoid async-signal-safety pitfalls.
public enum ProcessHost {
    /// Spawns `command`, wiring stdin to /dev/null and stdout/stderr to the given fds.
    /// Caller owns `outFD`/`errFD` and should close its copies after spawn returns.
    public static func spawn(
        command: String,
        useShell: Bool,
        directory: String?,
        environment: [String: String],
        outFD: Int32,
        errFD: Int32
    ) throws -> SpawnedProcess {
        let argv: [String]
        if useShell {
            argv = ["/bin/sh", "-c", command]
        } else {
            argv = try ShellLexer.tokenize(command)
        }
        guard let executable = argv.first else { throw ProcessHostError.invalidCommand }
        let resolvedExecutable = useShell ? executable : (PathUtil.resolveExecutable(executable, directory: directory) ?? executable)

        let fileActionsPtr = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
        defer { fileActionsPtr.deallocate() }
        posix_spawn_file_actions_init(fileActionsPtr)
        defer { posix_spawn_file_actions_destroy(fileActionsPtr) }

        posix_spawn_file_actions_addopen(fileActionsPtr, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(fileActionsPtr, outFD, 1)
        posix_spawn_file_actions_adddup2(fileActionsPtr, errFD, 2)

        if let directory {
            let expanded = PathUtil.expandTilde(directory)
            if #available(macOS 13, *) {
                posix_spawn_file_actions_addchdir_np(fileActionsPtr, expanded)
            }
        }

        let attrPtr = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
        defer { attrPtr.deallocate() }
        posix_spawnattr_init(attrPtr)
        defer { posix_spawnattr_destroy(attrPtr) }
        var flags: Int16 = Int16(POSIX_SPAWN_SETSID)
        flags |= Int16(POSIX_SPAWN_SETSIGDEF)
        flags |= Int16(POSIX_SPAWN_SETSIGMASK)
        // Without this, the child inherits every fd this process happens to have open at
        // spawn time that isn't individually marked O_CLOEXEC — the SQLite handle, kqueue
        // sources, a log window's O_EVTONLY watch — handing a managed process a live
        // descriptor onto Barback's own database (ex-F44, design.md §1 fault isolation).
        // 0/1/2 stay open regardless, since the file actions above explicitly target them.
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(attrPtr, flags)

        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(attrPtr, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(attrPtr, &emptyMask)

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { if let p = $0 { free(p) } } }

        var envList = environment.map { "\($0.key)=\($0.value)" }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envList.map { strdup($0) }
        cEnv.append(nil)
        defer { cEnv.forEach { if let p = $0 { free(p) } } }
        envList.removeAll()

        var pid: pid_t = 0
        let result = resolvedExecutable.withCString { execPath -> Int32 in
            posix_spawn(&pid, execPath, fileActionsPtr, attrPtr, &cArgs, &cEnv)
        }
        guard result == 0 else { throw ProcessHostError.posixSpawnFailed(result) }

        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let startTime: Double
        if size > 0 {
            startTime = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000.0
        } else {
            startTime = Date().timeIntervalSince1970
        }

        // SETSID makes the child its own session/process-group leader, so pgid == pid.
        return SpawnedProcess(pid: pid, pgid: pid, startTime: startTime)
    }

    public static func signal(pid: Int32, pgid: Int32?, name: String, asGroup: Bool) {
        let sig = signalNumber(name)
        if asGroup, let pgid {
            Darwin.kill(-pgid, sig)
        } else {
            Darwin.kill(pid, sig)
        }
    }

    public static func sendKill(pid: Int32, pgid: Int32?, asGroup: Bool) {
        if asGroup, let pgid {
            Darwin.kill(-pgid, SIGKILL)
        } else {
            Darwin.kill(pid, SIGKILL)
        }
    }

    public static func signalNumber(_ name: String) -> Int32 {
        switch name.uppercased().replacingOccurrences(of: "SIG", with: "") {
        case "TERM": return SIGTERM
        case "KILL": return SIGKILL
        case "INT": return SIGINT
        case "HUP": return SIGHUP
        case "QUIT": return SIGQUIT
        case "USR1": return SIGUSR1
        case "USR2": return SIGUSR2
        default: return SIGTERM
        }
    }

    /// Confirms a pid is still alive AND matches the recorded start time, guarding
    /// against PID reuse (design.md §3.7, REL-4).
    public static func verifyAlive(pid: Int32, expectedStartTime: Double, tolerance: Double = 1.0) -> Bool {
        guard Darwin.kill(pid, 0) == 0 else { return false }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0 else { return false }
        // A zombie still answers `kill(pid, 0)` and still reports its old start time, so
        // without this check a child whose NOTE_EXIT was somehow missed (the rare race
        // `reconcileLiveness`'s 300s safety net exists to catch) reads as "alive" forever —
        // the backstop backstops nothing (ex-F35, design.md §3.2/§3.7).
        guard info.pbi_status != UInt32(SZOMB) else { return false }
        let actual = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000.0
        return abs(actual - expectedStartTime) <= tolerance
    }
}
