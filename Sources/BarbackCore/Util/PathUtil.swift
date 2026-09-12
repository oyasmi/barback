import Foundation

public enum PathUtil {
    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static func homeDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Resolves the first token of a command to an executable path, honoring
    /// absolute/relative paths and `$PATH` lookup (mirrors POSIX exec search).
    public static func resolveExecutable(_ token: String, directory: String?, pathEnv: String? = nil) -> String? {
        let fm = FileManager.default

        func isExecutableFile(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
            return fm.isExecutableFile(atPath: path)
        }

        if token.contains("/") {
            let base = token.hasPrefix("/") || token.hasPrefix("~") ? expandTilde(token) :
                (directory.map { expandTilde($0) } ?? fm.currentDirectoryPath) + "/" + token
            return isExecutableFile(base) ? base : nil
        }

        let path = pathEnv ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = String(dir) + "/" + token
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }
}
