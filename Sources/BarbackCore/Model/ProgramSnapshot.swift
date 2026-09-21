import Foundation

/// Immutable snapshot of one managed program's live status, published by `Supervisor`
/// from the core queue to the main thread (design.md §2.2). The UI only ever reads these.
public struct ProgramSnapshot: Identifiable, Equatable, Sendable {
    public let program: Program
    public let serviceState: ServiceState?
    public let oneshotState: OneshotState?
    public let pid: Int32?
    public let startedAt: Date?
    public let retryCount: Int
    public let backoffRemaining: TimeInterval?
    public let lastRun: RunRecord?
    public let runCount: Int
    public let needsRestart: Bool

    public var id: Int64 { program.id }

    public var isActive: Bool {
        serviceState?.isActive ?? (oneshotState?.isActive ?? false)
    }

    public var statusText: String {
        switch program.kind {
        case .service:
            let s = serviceState ?? .stopped
            if s == .backoff, let remaining = backoffRemaining {
                return "\(s.displayText) \(retryCount)/\(program.startRetries) · \(Int(remaining))秒"
            }
            return s.displayText
        case .oneshot:
            if oneshotState == .running { return "执行中" }
            guard let last = lastRun else { return "尚未执行" }
            return (last.outcome ?? .unknown).displayText
        }
    }
}

public struct SupervisorSnapshot: Equatable, Sendable {
    public var programs: [ProgramSnapshot]
    public var recoveredCount: Int

    public init(programs: [ProgramSnapshot], recoveredCount: Int) {
        self.programs = programs
        self.recoveredCount = recoveredCount
    }

    public var runningCount: Int { programs.filter { $0.serviceState == .running }.count }
    /// Services that are neither settled-running nor settled-stopped. Without this the
    /// header's chips silently dropped them: three services with one in BACKOFF read as
    /// 「1 运行中 · 1 已停止」 and the third was simply missing from the tally.
    public var transitioningCount: Int {
        programs.filter { $0.serviceState == .starting || $0.serviceState == .backoff || $0.serviceState == .stopping }.count
    }
    public var stoppedCount: Int { programs.filter { $0.program.kind == .service && ($0.serviceState == .stopped || $0.serviceState == .exited) }.count }
    public var fatalCount: Int { programs.filter { $0.serviceState == .fatal }.count }
    public var oneshotRunningCount: Int { programs.filter { $0.oneshotState == .running }.count }
}
