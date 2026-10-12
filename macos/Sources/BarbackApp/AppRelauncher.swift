import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Starts Barback again after it quits, for 偏好设置 「立即重启」 (design.md §6.7).
///
/// A detached `/bin/sh` waits for this process to exit and only then `open`s the bundle.
/// Launching the new instance any earlier would be unsafe: nothing stops two instances from
/// running at once, and both would own the same database and its `live` table (§3.7).
enum AppRelauncher {
    /// Only a real `.app` can be reopened; a bare `swift run` binary cannot.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Polls for at most 60 s. If this process is somehow still alive by then the helper
    /// gives up rather than start a second instance beside it.
    private static let script = """
        i=0
        while kill -0 "$1" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -ge 300 ] && exit 1
          /bin/sleep 0.2
        done
        exec /usr/bin/open "$2"
        """

    /// Call once shutdown has finished, just before the process exits. The pid and bundle
    /// path travel as positional parameters, so no path ever needs shell quoting.
    @discardableResult
    static func spawnHelper() -> Bool {
        guard isAvailable else { return false }
        let argv = ["/bin/sh", "-c", script, "barback-relaunch", String(getpid()), Bundle.main.bundlePath]

        let fileActionsPtr = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
        defer { fileActionsPtr.deallocate() }
        posix_spawn_file_actions_init(fileActionsPtr)
        defer { posix_spawn_file_actions_destroy(fileActionsPtr) }
        posix_spawn_file_actions_addopen(fileActionsPtr, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(fileActionsPtr, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(fileActionsPtr, 2, "/dev/null", O_WRONLY, 0)

        let attrPtr = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
        defer { attrPtr.deallocate() }
        posix_spawnattr_init(attrPtr)
        defer { posix_spawnattr_destroy(attrPtr) }
        // Its own session, like a managed process (ProcessHost), so nothing that tears down
        // Barback's process group takes the helper with it; and none of Barback's descriptors
        // (the database among them) leak into it.
        posix_spawnattr_setflags(attrPtr, Int16(POSIX_SPAWN_SETSID) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        // Barback's own environment, so `open` runs in the same login session context.
        var cEnv: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { cEnv.forEach { if let p = $0 { free(p) } } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", fileActionsPtr, attrPtr, &cArgs, &cEnv)
        if result != 0 {
            NSLog("AppRelauncher: posix_spawn failed: \(String(cString: strerror(result)))")
        }
        return result == 0
    }
}
