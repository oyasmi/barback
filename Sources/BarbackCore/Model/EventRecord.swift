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
    case restartScheduled
    case enteredFatal
    case stopTimeout
    case logRotated
    case logWriteFailed
    case configChanged
    case imported
    case wakeReconcile
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
