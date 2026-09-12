import Foundation

public enum RunTrigger: String, Codable, Sendable {
    case manual
    case autostart
    case autorestart
    case retry
}

public enum RunOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case timeout
    case cancelled
    case unknown
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
