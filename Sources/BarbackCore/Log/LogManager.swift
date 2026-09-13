import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct LogFDs {
    public let outFD: Int32
    public let errFD: Int32
    public let outPath: String
    public let errPath: String
}

public enum LogManagerError: Error, LocalizedError {
    case openFailed(String)
    public var errorDescription: String? {
        switch self {
        case .openFailed(let p): return "无法打开日志文件：\(p)"
        }
    }
}

/// Opens fds for child stdout/stderr and rotates service logs by copytruncate
/// (design.md §4, D-6/D-7). Barback never reads the data stream — it only opens the fd
/// and hands it to `posix_spawn`, so log throughput costs ~0 CPU in the parent.
public enum LogManager {
    /// Where a service's stdout/stderr land, shared between `openServiceLogs` and the
    /// rotation call sites in `Supervisor` so both agree on the same paths without a running
    /// process (design.md §4).
    /// Explicit paths are expanded here — and only here plus `ProgramLogPath.resolve`, the
    /// two other places a `logPath`/`logStderrPath` string turns into an actual filesystem
    /// path — so a form value like `~/logs/app.log` means the same thing everywhere instead
    /// of `open()` seeing a literal `~` and failing (ex-F33).
    public static func serviceLogPaths(name: String, logsDir: String, mergeStderr: Bool, explicitOutPath: String?, explicitErrPath: String?) -> (out: String, err: String) {
        let dir = (logsDir as NSString).appendingPathComponent("programs")
        let outPath = explicitOutPath.map(PathUtil.expandTilde) ?? (dir as NSString).appendingPathComponent("\(name).out.log")
        let errPath = mergeStderr ? outPath : (explicitErrPath.map(PathUtil.expandTilde) ?? (dir as NSString).appendingPathComponent("\(name).err.log"))
        return (outPath, errPath)
    }

    public static func openServiceLogs(name: String, logsDir: String, mergeStderr: Bool, explicitOutPath: String?, explicitErrPath: String?) throws -> LogFDs {
        let paths = serviceLogPaths(name: name, logsDir: logsDir, mergeStderr: mergeStderr, explicitOutPath: explicitOutPath, explicitErrPath: explicitErrPath)
        let outPath = paths.out
        let errPath = paths.err
        // Creates the parent of whatever path is actually in play — the default
        // `programs/` dir when no explicit path was given, or an explicit path's own parent
        // otherwise, which used to only ever exist if the user had created it by hand first
        // (ex-F33).
        try FileManager.default.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if errPath != outPath {
            try FileManager.default.createDirectory(atPath: (errPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }

        let outFD = open(outPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard outFD >= 0 else { throw LogManagerError.openFailed(outPath) }

        let errFD: Int32
        if mergeStderr {
            errFD = dup(outFD)
        } else {
            errFD = open(errPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        }
        guard errFD >= 0 else { close(outFD); throw LogManagerError.openFailed(errPath) }

        writeSeparatorLine(fd: outFD, name: name)
        return LogFDs(outFD: outFD, errFD: errFD, outPath: outPath, errPath: errPath)
    }

    public static func openRunLog(name: String, runId: Int64, logsDir: String) throws -> LogFDs {
        let dir = (logsDir as NSString).appendingPathComponent("runs")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(name)-\(runId).log")
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw LogManagerError.openFailed(path) }
        writeSeparatorLine(fd: fd, name: name)
        return LogFDs(outFD: fd, errFD: dup(fd), outPath: path, errPath: path)
    }

    public static func closeFDs(_ fds: LogFDs) {
        close(fds.outFD)
        if fds.errFD != fds.outFD { close(fds.errFD) }
    }

    private static func writeSeparatorLine(fd: Int32, name: String, pid: Int32? = nil) {
        let formatter = ISO8601DateFormatter()
        var line = "\n----- \(formatter.string(from: Date())) start \(name)"
        if let pid { line += " pid=\(pid)" }
        line += " -----\n"
        line.withCString { cstr in
            _ = write(fd, cstr, strlen(cstr))
        }
    }

    /// Copy-then-truncate rotation (design.md D-7): only way to keep the child's fd valid
    /// since it holds the file open via O_APPEND on the original inode.
    /// `force` rotates regardless of size — used for the `.onRestart` policy, where "rotate"
    /// means "every fresh process gets a clean file" rather than "this file got too big".
    public static func rotateIfNeeded(path: String, maxBytes: Int64, backups: Int, force: Bool = false) throws -> Bool {
        guard force || maxBytes > 0 else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attrs?[.size] as? Int64 else { return false }
        guard force ? size > 0 : size >= maxBytes else { return false }

        let fm = FileManager.default
        if backups > 0 {
            let oldest = "\(path).\(backups)"
            try? fm.removeItem(atPath: oldest)
            var n = backups - 1
            while n >= 1 {
                let src = "\(path).\(n)"
                let dst = "\(path).\(n + 1)"
                if fm.fileExists(atPath: src) {
                    try? fm.removeItem(atPath: dst)
                    try? fm.moveItem(atPath: src, toPath: dst)
                }
                n -= 1
            }
            try? fm.copyItem(atPath: path, toPath: "\(path).1")
        }

        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        ftruncate(fd, 0)
        let marker = "----- rotated \(ISO8601DateFormatter().string(from: Date())) -----\n"
        marker.withCString { cstr in _ = write(fd, cstr, strlen(cstr)) }
        return true
    }
}
