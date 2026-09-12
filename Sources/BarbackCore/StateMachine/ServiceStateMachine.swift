import Foundation

/// Inputs the state machine can react to.
public enum ServiceEvent: Sendable, Equatable {
    case start(trigger: RunTrigger)
    case stop
    case spawnSucceeded(pid: Int32, pgid: Int32, procStartTime: Double, at: Date)
    case spawnFailed
    case startSecondsElapsed
    case processExited(code: Int32?, signal: Int32?, at: Date)
    case backoffElapsed
    case stopTimerElapsed
    case clearFatal
    case forceKill
}

/// Side effects the machine wants performed. `Supervisor` executes these against real
/// processes/timers/the store; the machine itself never touches the outside world.
public enum ServiceAction: Sendable, Equatable {
    case spawn(trigger: RunTrigger)
    case scheduleStartTimer(seconds: Double)
    case cancelStartTimer
    case scheduleBackoffTimer(seconds: Double)
    case cancelBackoffTimer
    case sendSignal(name: String, group: Bool)
    case scheduleStopTimer(seconds: Double)
    case cancelStopTimer
    /// Carries the pid/pgid to kill rather than leaving the caller to re-read `ServiceRuntime`
    /// at execution time — some transitions clear those fields in the very same reduction
    /// that emits this action, which used to make the kill silently a no-op (ex-F21).
    case sendKill(pid: Int32?, pgid: Int32?, group: Bool)
    case scheduleStopGrace(seconds: Double)
    case persistLive
    case publishSnapshot
    case notify(NotificationKind)
    case logEvent(EventType, level: EventLevel, detail: [String: String])
    case finalizeRun(outcome: RunOutcome, code: Int32?, signal: Int32?)
}

public enum NotificationKind: Sendable, Equatable {
    case enteredFatal(name: String)
    case unexpectedRestart(name: String)
    case stopTimeout(name: String)
}

/// Pure state carried by the machine between reductions. This is the in-memory mirror of
/// the `live` table row plus a small amount of derived bookkeeping (storm window).
public struct ServiceRuntime: Sendable, Equatable {
    public var state: ServiceState
    public var retryCount: Int
    public var stopRequested: Bool
    public var restartTimestamps: [Date]
    public var pid: Int32?
    public var pgid: Int32?
    public var procStartTime: Double?
    public var startedAt: Date?

    public init(
        state: ServiceState = .stopped,
        retryCount: Int = 0,
        stopRequested: Bool = false,
        restartTimestamps: [Date] = [],
        pid: Int32? = nil,
        pgid: Int32? = nil,
        procStartTime: Double? = nil,
        startedAt: Date? = nil
    ) {
        self.state = state
        self.retryCount = retryCount
        self.stopRequested = stopRequested
        self.restartTimestamps = restartTimestamps
        self.pid = pid
        self.pgid = pgid
        self.procStartTime = procStartTime
        self.startedAt = startedAt
    }
}

/// Pure reducer implementing design.md §3.3. No I/O — callers apply the returned actions.
public enum ServiceStateMachine {
    public static func reduce(
        runtime: ServiceRuntime,
        event: ServiceEvent,
        config: Program
    ) -> (ServiceRuntime, [ServiceAction]) {
        var r = runtime
        var actions: [ServiceAction] = []

        switch (r.state, event) {

        // --- start from an inactive state ---
        case (.stopped, .start(let trigger)),
             (.exited, .start(let trigger)),
             (.fatal, .start(let trigger)):
            r.retryCount = 0
            r.stopRequested = false
            r.state = .starting
            actions.append(.spawn(trigger: trigger))
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.fatal, .clearFatal):
            r.state = .stopped
            r.retryCount = 0
            r.restartTimestamps = []
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        // record spawn identity once posix_spawn succeeds
        case (.starting, .spawnSucceeded(let pid, let pgid, let startTime, let at)):
            r.pid = pid
            r.pgid = pgid
            r.procStartTime = startTime
            r.startedAt = at
            actions.append(.logEvent(.processSpawned, level: .info, detail: ["pid": String(pid)]))
            if config.startSeconds <= 0 {
                r.state = .running
                r.retryCount = 0
                actions.append(.publishSnapshot)
            } else {
                actions.append(.scheduleStartTimer(seconds: Double(config.startSeconds)))
            }
            actions.append(.persistLive)

        case (.starting, .spawnFailed):
            r.pid = nil
            (r, actions) = enterBackoffOrFatal(r, config: config)

        case (.starting, .startSecondsElapsed):
            r.state = .running
            r.retryCount = 0
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.starting, .processExited(let code, let signal, _)):
            actions.append(.cancelStartTimer)
            actions.append(.finalizeRun(outcome: .failed, code: code, signal: signal))
            (r, actions) = appendActions(enterBackoffOrFatal(r, config: config), to: actions)

        // --- running: exit disposition depends on autorestart policy ---
        case (.running, .processExited(let code, let signal, _)):
            actions.append(.finalizeRun(outcome: exitedOutcome(code: code, exitCodes: config.exitCodes), code: code, signal: signal))
            switch config.autorestart {
            case .never:
                r.state = .exited
                r.pid = nil
                actions.append(.persistLive)
                actions.append(.publishSnapshot)
            case .always:
                // `.always` used to spawn again unconditionally with no record kept anywhere —
                // a service that starts fine and then reliably exits after a few seconds
                // (bad config, a periodic OOM) would restart forever at `startSeconds` cadence,
                // each cycle adding a run row, event rows, and log lines that nothing ever
                // trims (design.md §3.3, ex-F24). Route it through the same storm window
                // `.unexpected` already uses instead of a policy-shaped exemption from it.
                recordRestart(&r, config: config)
                if isStorming(r.restartTimestamps, config: config) {
                    r.state = .fatal
                    r.pid = nil
                    actions.append(.logEvent(.enteredFatal, level: .error, detail: ["reason": "crash_storm"]))
                    actions.append(.notify(.enteredFatal(name: config.name)))
                    actions.append(.persistLive)
                    actions.append(.publishSnapshot)
                } else {
                    r.state = .starting
                    r.pid = nil
                    r.retryCount = 0
                    actions.append(.spawn(trigger: .autorestart))
                    actions.append(.persistLive)
                    actions.append(.publishSnapshot)
                }
            case .unexpected:
                let isExpected = code.map { config.exitCodes.contains($0) } ?? false
                if isExpected {
                    r.state = .exited
                    r.pid = nil
                    actions.append(.persistLive)
                    actions.append(.publishSnapshot)
                } else {
                    recordRestart(&r, config: config)
                    if isStorming(r.restartTimestamps, config: config) {
                        r.state = .fatal
                        r.pid = nil
                        actions.append(.logEvent(.enteredFatal, level: .error, detail: ["reason": "crash_storm"]))
                        actions.append(.notify(.enteredFatal(name: config.name)))
                        actions.append(.persistLive)
                        actions.append(.publishSnapshot)
                    } else {
                        r.state = .starting
                        r.pid = nil
                        r.retryCount = 0
                        actions.append(.notify(.unexpectedRestart(name: config.name)))
                        actions.append(.spawn(trigger: .autorestart))
                        actions.append(.persistLive)
                        actions.append(.publishSnapshot)
                    }
                }
            }

        // --- backoff ---
        case (.backoff, .backoffElapsed):
            r.state = .starting
            actions.append(.spawn(trigger: .retry))
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.backoff, .stop):
            r.state = .stopped
            r.stopRequested = true
            actions.append(.cancelBackoffTimer)
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        // --- stop from any active state ---
        case (.starting, .stop), (.running, .stop):
            r.state = .stopping
            r.stopRequested = true
            actions.append(.sendSignal(name: config.stopSignal, group: config.stopAsGroup))
            actions.append(.scheduleStopTimer(seconds: Double(config.stopWaitSeconds)))
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.stopping, .processExited(let code, let signal, _)):
            actions.append(.cancelStopTimer)
            if config.killAsGroup, let pgid = r.pgid {
                // The leader already exited; this is purely a group sweep for anything it
                // forked. Capturing pgid now — before it is cleared below — is what makes
                // this sweep actually run (ex-F21: it used to read a runtime already nil'd out).
                actions.append(.sendKill(pid: nil, pgid: pgid, group: true))
            }
            actions.append(.finalizeRun(outcome: .cancelled, code: code, signal: signal))
            r.state = .stopped
            r.pid = nil
            r.pgid = nil
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.stopping, .stopTimerElapsed):
            // SIGKILL escalation looks at `killAsGroup`, not `stopAsGroup` — that flag governs
            // the stop *signal*, and conflating the two meant toggling one didn't reliably
            // change the other's behavior (ex-F14).
            actions.append(.sendKill(pid: r.pid, pgid: r.pgid, group: config.killAsGroup))
            actions.append(.notify(.stopTimeout(name: config.name)))
            actions.append(.logEvent(.stopTimeout, level: .warn, detail: [:]))
            actions.append(.scheduleStopGrace(seconds: 2))

        case (.stopping, .forceKill):
            actions.append(.sendKill(pid: r.pid, pgid: r.pgid, group: config.killAsGroup))

        default:
            // No-op for events that don't apply to the current state.
            break
        }

        return (r, actions)
    }

    private static func appendActions(_ pair: (ServiceRuntime, [ServiceAction]), to prefix: [ServiceAction]) -> (ServiceRuntime, [ServiceAction]) {
        (pair.0, prefix + pair.1)
    }

    private static func exitedOutcome(code: Int32?, exitCodes: [Int32]) -> RunOutcome {
        if let code, exitCodes.contains(code) { return .succeeded }
        return .failed
    }

    private static func isStorming(_ timestamps: [Date], config: Program) -> Bool {
        let window = TimeInterval(config.stormWindowSec)
        let cutoff = Date().addingTimeInterval(-window)
        let recent = timestamps.filter { $0 >= cutoff }
        return recent.count >= config.stormMaxRestarts
    }

    /// Appends a restart timestamp, pruning everything already outside the storm window first
    /// — `restartTimestamps` used to only ever grow, one entry per unexpected exit for the
    /// life of a long-running service (design.md §3.3, ex-F20).
    private static func recordRestart(_ r: inout ServiceRuntime, config: Program) {
        let cutoff = Date().addingTimeInterval(-TimeInterval(config.stormWindowSec))
        r.restartTimestamps = r.restartTimestamps.filter { $0 >= cutoff }
        r.restartTimestamps.append(Date())
    }

    private static func enterBackoffOrFatal(_ runtime: ServiceRuntime, config: Program) -> (ServiceRuntime, [ServiceAction]) {
        var r = runtime
        // A backoff/fatal transition always follows an exit, so any pid it was holding is
        // already dead — leaving it set persisted a dead pid into `live` (ex-F29), relying on
        // `verifyAlive`'s 1s start-time tolerance to avoid mistaking a reused pid for it.
        r.pid = nil
        r.pgid = nil
        var actions: [ServiceAction] = []
        if r.retryCount + 1 < config.startRetries {
            r.retryCount += 1
            r.state = .backoff
            let delay = backoffDelay(retryCount: r.retryCount, base: config.backoffBase, max: config.backoffMax)
            actions.append(.scheduleBackoffTimer(seconds: delay))
            actions.append(.logEvent(.restartScheduled, level: .warn, detail: ["retry": String(r.retryCount), "delay": String(delay)]))
        } else {
            r.state = .fatal
            actions.append(.logEvent(.enteredFatal, level: .error, detail: ["reason": "retries_exhausted"]))
            actions.append(.notify(.enteredFatal(name: config.name)))
        }
        actions.append(.persistLive)
        actions.append(.publishSnapshot)
        return (r, actions)
    }

    /// `delay = min(base * 2^(n-1), max)` with ±20% jitter (design.md §3.3).
    public static func backoffDelay(retryCount n: Int, base: Double, max maxDelay: Double, jitter: Double = 0.2, random: () -> Double = { Double.random(in: -1...1) }) -> Double {
        let raw = min(base * pow(2.0, Double(n - 1)), maxDelay)
        let jitterAmount = raw * jitter * random()
        return Swift.max(0.01, raw + jitterAmount)
    }
}
