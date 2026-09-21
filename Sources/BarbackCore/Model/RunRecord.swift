import Foundation

public enum RunTrigger: String, Codable, Sendable {
    case manual
    case autostart
    case autorestart
    case retry

    public var displayText: String {
        switch self {
        case .manual: return "手动"
        case .autostart: return "开机自启"
        case .autorestart: return "自动重启"
        case .retry: return "重试"
        }
    }
}

public enum RunOutcome: String, Codable, Sendable, CaseIterable {
    case succeeded
    case failed
    case timeout
    case cancelled
    case unknown

    /// The raw values are storage, not copy. They were reaching the history table and the
    /// config sidebar verbatim, so a Chinese UI showed 「succeeded」 in two places while the
    /// status panel showed 「成功」 for the same run.
    public var displayText: String {
        switch self {
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .timeout: return "超时"
        case .cancelled: return "已中止"
        case .unknown: return "结果未知"
        }
    }
}

/// One row of the `run` table: one service start, or one oneshot execution.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var programId: Int64
    public var trigger: RunTrigger
    public var pid: Int32?
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var termSignal: Int32?
    public var outcome: RunOutcome?
    public var logPath: String?

    public init(
        id: Int64 = 0,
        programId: Int64,
        trigger: RunTrigger,
        pid: Int32? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        termSignal: Int32? = nil,
        outcome: RunOutcome? = nil,
        logPath: String? = nil
    ) {
        self.id = id
        self.programId = programId
        self.trigger = trigger
        self.pid = pid
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.termSignal = termSignal
        self.outcome = outcome
        self.logPath = logPath
    }

    public var duration: TimeInterval? {
        guard let ended = endedAt else { return nil }
        return ended.timeIntervalSince(startedAt)
    }
}
