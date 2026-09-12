import Foundation

/// Service state machine states (design.md §3.3, requirements.md §3.1).
public enum ServiceState: String, Codable, Sendable, Equatable {
    case stopped = "STOPPED"
    case starting = "STARTING"
    case running = "RUNNING"
    case backoff = "BACKOFF"
    case stopping = "STOPPING"
    case exited = "EXITED"
    case fatal = "FATAL"

    public var isActive: Bool {
        switch self {
        case .starting, .running, .stopping, .backoff: return true
        case .stopped, .exited, .fatal: return false
        }
    }

    public var displayText: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .backoff: return "重试中"
        case .stopping: return "停止中"
        case .exited: return "已退出"
        case .fatal: return "启动失败"
        }
    }
}

/// One-shot command lifecycle states (design.md §3.4).
public enum OneshotState: String, Codable, Sendable, Equatable {
    case idle = "IDLE"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case timeout = "TIMEOUT"
    case cancelled = "CANCELLED"

    public var isActive: Bool { self == .running }

    public var displayText: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "执行中"
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .timeout: return "超时"
        case .cancelled: return "已中止"
        }
    }
}

/// Runtime snapshot persisted in the `live` table — the sole basis for crash recovery.
public struct LiveRecord: Codable, Sendable, Equatable {
    public var programId: Int64
    public var appBootId: String
    public var state: String
    public var pid: Int32?
    public var pgid: Int32?
    public var procStartTime: Double?
    public var startedAt: Double?
    public var retryCount: Int
    public var stopRequested: Bool
    public var runId: Int64?
    public var needsRestart: Bool

    public init(
        programId: Int64,
        appBootId: String,
        state: String,
        pid: Int32? = nil,
        pgid: Int32? = nil,
        procStartTime: Double? = nil,
        startedAt: Double? = nil,
        retryCount: Int = 0,
        stopRequested: Bool = false,
        runId: Int64? = nil,
        needsRestart: Bool = false
    ) {
        self.programId = programId
        self.appBootId = appBootId
        self.state = state
        self.pid = pid
        self.pgid = pgid
        self.procStartTime = procStartTime
        self.startedAt = startedAt
        self.retryCount = retryCount
        self.stopRequested = stopRequested
        self.runId = runId
        self.needsRestart = needsRestart
    }
}
