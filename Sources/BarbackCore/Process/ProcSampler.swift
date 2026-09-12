import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProcSample: Sendable, Equatable {
    public let cpuPercent: Double
    public let rssBytes: UInt64
}

/// On-demand CPU/RSS sampling (design.md §2.1: ProcSampler). Only invoked while a menu
/// or window that displays the numbers is open — never on a timer while idle.
public enum ProcSampler {
    private final class Box: @unchecked Sendable {
        var lastCPUTime: [Int32: (total: Double, wall: Double)] = [:]
    }
    private static let box = Box()
    private static let lock = NSLock()

    public static func sample(pid: Int32) -> ProcSample? {
        var taskInfo = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
        guard size > 0 else { return nil }

        let totalCPUNanos = Double(taskInfo.pti_total_user) + Double(taskInfo.pti_total_system)
        let totalCPUSeconds = totalCPUNanos / 1_000_000_000.0
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let previous = box.lastCPUTime[pid]
        box.lastCPUTime[pid] = (totalCPUSeconds, now)
        lock.unlock()

        var cpuPercent = 0.0
        if let previous, now > previous.wall {
            let deltaCPU = totalCPUSeconds - previous.total
            let deltaWall = now - previous.wall
            let maxPercent = 100.0 * Double(ProcessInfo.processInfo.activeProcessorCount)
            cpuPercent = max(0, min(maxPercent, (deltaCPU / deltaWall) * 100))
        }

        return ProcSample(cpuPercent: cpuPercent, rssBytes: taskInfo.pti_resident_size)
    }

    public static func clearHistory(pid: Int32) {
        lock.lock()
        box.lastCPUTime.removeValue(forKey: pid)
        lock.unlock()
    }
}
