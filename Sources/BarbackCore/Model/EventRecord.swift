import Foundation

public enum EventLevel: String, Codable, Sendable {
    case info
    case warn
    case error
}

public enum EventType: String, Codable, Sendable {
    case appStarted
    case appStopping
    case recoveredFromCrash
    case stateChanged
    case processSpawned
    case processExited
    case spawnFailed
    case restartScheduled
    case enteredFatal
    case stopTimeout
    case logRotated
    case logWriteFailed
    case configChanged
    case imported
    case wakeReconcile

    /// The event window showed these identifiers as-is — a log of `stateChanged` /
    /// `restartScheduled` rows in an otherwise Chinese UI, and one that assumes the reader
    /// knows the code.
    public var displayText: String {
        switch self {
        case .appStarted: return "Barback 启动"
        case .appStopping: return "Barback 退出中"
        case .recoveredFromCrash: return "崩溃后接管"
        case .stateChanged: return "状态变化"
        case .processSpawned: return "进程已启动"
        case .processExited: return "进程已退出"
        case .spawnFailed: return "启动失败"
        case .restartScheduled: return "已排定重试"
        case .enteredFatal: return "进入启动失败"
        case .stopTimeout: return "停止超时"
        case .logRotated: return "日志已轮转"
        case .logWriteFailed: return "日志写入失败"
        case .configChanged: return "配置已修改"
        case .imported: return "已导入"
        case .wakeReconcile: return "唤醒后核对"
        }
    }
}

public struct EventRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var ts: Date
    public var level: EventLevel
    public var programId: Int64?
    public var type: EventType
    public var detailJSON: String

    public init(
        id: Int64 = 0,
        ts: Date = Date(),
        level: EventLevel,
        programId: Int64? = nil,
        type: EventType,
        detailJSON: String = "{}"
    ) {
        self.id = id
        self.ts = ts
        self.level = level
        self.programId = programId
        self.type = type
        self.detailJSON = detailJSON
    }
}
