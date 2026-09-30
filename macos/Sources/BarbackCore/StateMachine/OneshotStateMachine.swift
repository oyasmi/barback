import Foundation

public enum OneshotEvent: Sendable, Equatable {
    case run
    case cancel
    case spawnSucceeded(pid: Int32, pgid: Int32, procStartTime: Double, at: Date)
    /// `reason` mirrors `ServiceEvent.spawnFailed` — the caller's description of why the
    /// spawn attempt itself failed, threaded through so the reducer can log it (ex-F34).
    case spawnFailed(reason: String)
    case processExited(code: Int32?, signal: Int32?, at: Date)
    case timeoutElapsed
    case stopTimerElapsed
}

public enum OneshotAction: Sendable, Equatable {
    case spawn
    case sendSignal(name: String, group: Bool)
    case scheduleStopTimer(seconds: Double)
    case cancelStopTimer
    case scheduleTimeoutTimer(seconds: Double)
    case cancelTimeoutTimer
    case sendKill(group: Bool)
    case persistLive
    case publishSnapshot
    /// `duration` is computed here from `procStartTime` and the exit event's own timestamp —
    /// never re-derived by the caller after the fact. It used to be read back from `Store`
    /// inside `Supervisor.perform`, by which point `.finalizeRun` (dispatched just before
    /// `.notify` in every branch below) had already cleared `currentRunId`, so the lookup
    /// always missed and every completion notification read "0.0s" (ex-F32).
    case notify(outcome: OneshotState, duration: TimeInterval)
    case logEvent(EventType, level: EventLevel, detail: [String: String])
    case finalizeRun(outcome: RunOutcome, code: Int32?, signal: Int32?)
}

public struct OneshotRuntime: Sendable, Equatable {
    public var state: OneshotState
    public var pid: Int32?
    public var pgid: Int32?
    public var procStartTime: Double?
    public var stopRequested: Bool
    public var timedOut: Bool

    public init(state: OneshotState = .idle, pid: Int32? = nil, pgid: Int32? = nil, procStartTime: Double? = nil, stopRequested: Bool = false, timedOut: Bool = false) {
        self.state = state
        self.pid = pid
        self.pgid = pgid
        self.procStartTime = procStartTime
        self.stopRequested = stopRequested
        self.timedOut = timedOut
    }
}

/// Pure reducer for one-shot commands (design.md §3.4). Never retries on its own.
public enum OneshotStateMachine {
    public static func reduce(
        runtime: OneshotRuntime,
        event: OneshotEvent,
        config: Program
    ) -> (OneshotRuntime, [OneshotAction]) {
        var r = runtime
        var actions: [OneshotAction] = []

        switch (r.state, event) {
        case (.idle, .run), (.succeeded, .run), (.failed, .run), (.timeout, .run), (.cancelled, .run):
            r.state = .running
            r.stopRequested = false
            r.timedOut = false
            actions.append(.spawn)
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        // A concurrent-run branch used to live here, but `OneshotRuntime`/`currentRunId` only
        // ever track one pid at a time: a second spawn while the first was still running would
        // silently overwrite its pid, so whichever process exited first pushed the *other*
        // one's run row to `.succeeded` and left it with `ended_at` permanently NULL
        // (design.md §3.4, ex-F12). `Supervisor.dispatchOneshotEvent` now refuses a `.run`
        // while already running, so this state is unreachable — removed rather than left as
        // a second guard nothing can trigger.

        case (.running, .spawnSucceeded(let pid, let pgid, let startTime, _)):
            r.pid = pid
            r.pgid = pgid
            r.procStartTime = startTime
            if config.timeoutSeconds > 0 {
                actions.append(.scheduleTimeoutTimer(seconds: Double(config.timeoutSeconds)))
            }
            actions.append(.persistLive)

        case (.running, .spawnFailed(let reason)):
            r.state = .failed
            actions.append(.logEvent(.spawnFailed, level: .error, detail: ["reason": reason]))
            actions.append(.finalizeRun(outcome: .failed, code: nil, signal: nil))
            actions.append(.notify(outcome: .failed, duration: 0))
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.running, .processExited(let code, let signal, let at)):
            actions.append(.cancelTimeoutTimer)
            actions.append(.cancelStopTimer)
            let outcome: OneshotState
            let runOutcome: RunOutcome
            if r.timedOut {
                outcome = .timeout
                runOutcome = .timeout
            } else if r.stopRequested {
                outcome = .cancelled
                runOutcome = .cancelled
            } else if let code, config.exitCodes.contains(code) {
                outcome = .succeeded
                runOutcome = .succeeded
            } else {
                outcome = .failed
                runOutcome = .failed
            }
            // `r.procStartTime` is the OS-reported spawn instant (from `proc_pidinfo`, set in
            // `.spawnSucceeded` and never cleared before this branch runs), so duration needs
            // no Store round-trip and survives a crash-recovery adoption just as well as a
            // normal run (ex-F32).
            let duration = r.procStartTime.map { max(0, at.timeIntervalSince1970 - $0) } ?? 0
            r.state = outcome
            r.pid = nil
            r.pgid = nil
            actions.append(.logEvent(.processExited, level: outcome == .succeeded ? .info : .warn, detail: exitDetail(code: code, signal: signal)))
            actions.append(.finalizeRun(outcome: runOutcome, code: code, signal: signal))
            actions.append(.notify(outcome: outcome, duration: duration))
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.running, .timeoutElapsed):
            r.timedOut = true
            r.stopRequested = true
            actions.append(.sendSignal(name: config.stopSignal, group: config.stopAsGroup))
            actions.append(.scheduleStopTimer(seconds: Double(config.stopWaitSeconds)))
            actions.append(.persistLive)

        case (.running, .cancel):
            r.stopRequested = true
            actions.append(.sendSignal(name: config.stopSignal, group: config.stopAsGroup))
            actions.append(.scheduleStopTimer(seconds: Double(config.stopWaitSeconds)))
            actions.append(.persistLive)

        case (.running, .stopTimerElapsed):
            // SIGKILL escalation looks at `killAsGroup` only — `stopAsGroup` governs the stop
            // *signal*, not the kill that follows when the process ignores it (ex-F14).
            actions.append(.sendKill(group: config.killAsGroup))

        default:
            break
        }

        return (r, actions)
    }

    private static func exitDetail(code: Int32?, signal: Int32?) -> [String: String] {
        var detail: [String: String] = [:]
        if let code { detail["code"] = String(code) }
        if let signal { detail["signal"] = String(signal) }
        return detail
    }
}
