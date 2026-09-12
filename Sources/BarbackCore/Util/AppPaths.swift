import Foundation

/// Well-known filesystem locations (design.md §5.1).
public enum AppPaths {
    public static var applicationSupportDir: String {
        (homeDir as NSString).appendingPathComponent("Library/Application Support/Barback")
    }

    public static var dbPath: String {
        (applicationSupportDir as NSString).appendingPathComponent("barback.db")
    }

    public static var backupsDir: String {
        (applicationSupportDir as NSString).appendingPathComponent("backups")
    }

    public static var logsDir: String {
        (homeDir as NSString).appendingPathComponent("Library/Logs/Barback")
    }

    public static var selfLogPath: String {
        (logsDir as NSString).appendingPathComponent("barback.log")
    }

    public static var programsLogsDir: String {
        (logsDir as NSString).appendingPathComponent("programs")
    }

    public static var runsLogsDir: String {
        (logsDir as NSString).appendingPathComponent("runs")
    }

    private static var homeDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for path in [applicationSupportDir, backupsDir, logsDir, programsLogsDir, runsLogsDir] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
