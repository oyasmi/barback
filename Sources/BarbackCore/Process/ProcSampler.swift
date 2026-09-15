import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProcSample: Sendable, Equatable {
    /// CPU% is a difference between two samples, so it is `nil` on the first sample of a
    /// pid — there is nothing to subtract yet. Reporting that baseline as `0.0` made every
    /// reading in the panel a permanent "0.0%", since the panel samples once per open.
    public let cpuPercent: Double?
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

    /// `proc_taskinfo`'s CPU totals are in **mach time units, not nanoseconds** — a detail
    /// that costs nothing on Intel (timebase 1/1) and a factor of 41.67 on Apple Silicon
    /// (125/3), which is why a fully pegged core used to read as 2.4%.
    private static let nanosecondsPerMachTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    public static func sample(pid: Int32) -> ProcSample? {
        var taskInfo = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
        guard size > 0 else { return nil }

        let totalCPUTicks = Double(taskInfo.pti_total_user) + Double(taskInfo.pti_total_system)
        let totalCPUSeconds = totalCPUTicks * nanosecondsPerMachTick / 1_000_000_000.0
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let previous = box.lastCPUTime[pid]
        box.lastCPUTime[pid] = (totalCPUSeconds, now)
        lock.unlock()

        // A window shorter than this is mostly scheduling noise divided by a tiny number,
        // which reads as a wild percentage rather than a measurement.
        var cpuPercent: Double?
        if let previous, now - previous.wall >= 0.1 {
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
