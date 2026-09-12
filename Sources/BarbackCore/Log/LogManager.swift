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
    public static func openServiceLogs(name: String, logsDir: String, mergeStderr: Bool, explicitOutPath: String?, explicitErrPath: String?) throws -> LogFDs {
        let dir = (logsDir as NSString).appendingPathComponent("programs")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let outPath = explicitOutPath ?? (dir as NSString).appendingPathComponent("\(name).out.log")
        let errPath = mergeStderr ? outPath : (explicitErrPath ?? (dir as NSString).appendingPathComponent("\(name).err.log"))

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
    public static func rotateIfNeeded(path: String, maxBytes: Int64, backups: Int) throws -> Bool {
        guard maxBytes > 0 else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attrs?[.size] as? Int64, size >= maxBytes else { return false }

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
