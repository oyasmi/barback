import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ExitStatus: Sendable, Equatable {
    public let code: Int32?
    public let signal: Int32?
}

/// Zero-polling exit detection via kqueue `EVFILT_PROC/NOTE_EXIT`
/// (`DispatchSource.makeProcessSource`), per design.md §3.2 / D-5.
/// Works for non-child (adopted orphan) pids too, though `waitpid` then can't reap them.
public final class ExitWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private let lock = NSLock()

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Registers for exit notification. `isOwnChild` controls whether we `waitpid` to reap
    /// the zombie and retrieve the real exit status; adopted orphans can't be waited on by us.
    public func register(pid: Int32, isOwnChild: Bool, onExit: @escaping @Sendable (ExitStatus) -> Void) {
        lock.lock()
        if sources[pid] != nil {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleExit(pid: pid, isOwnChild: isOwnChild, onExit: onExit)
        }
        sources[pid] = source
        source.resume()
        lock.unlock()
    }

    public func unregister(pid: Int32) {
        lock.lock()
        if let source = sources.removeValue(forKey: pid) {
            source.cancel()
        }
        lock.unlock()
    }

    private func handleExit(pid: Int32, isOwnChild: Bool, onExit: @escaping @Sendable (ExitStatus) -> Void) {
        unregister(pid: pid)
        var status: ExitStatus
        if isOwnChild {
            var rawStatus: Int32 = 0
            let result = waitpid(pid, &rawStatus, WNOHANG)
            if result == pid {
                if (rawStatus & 0x7f) == 0 {
                    status = ExitStatus(code: (rawStatus >> 8) & 0xff, signal: nil)
                } else {
                    status = ExitStatus(code: nil, signal: rawStatus & 0x7f)
                }
            } else {
                status = ExitStatus(code: nil, signal: nil)
            }
        } else {
            // Adopted orphan: exited but not our child, status unknown (design.md §3.2).
            status = ExitStatus(code: nil, signal: nil)
        }
        onExit(status)
    }
}
