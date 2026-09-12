import Foundation

public enum OneshotEvent: Sendable, Equatable {
    case run
    case cancel
    case spawnSucceeded(pid: Int32, pgid: Int32, procStartTime: Double, at: Date)
    case spawnFailed
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
    case notify(outcome: OneshotState)
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

        case (.running, .spawnFailed):
            r.state = .failed
            actions.append(.finalizeRun(outcome: .failed, code: nil, signal: nil))
            actions.append(.notify(outcome: .failed))
            actions.append(.persistLive)
            actions.append(.publishSnapshot)

        case (.running, .processExited(let code, let signal, _)):
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
            r.state = outcome
            r.pid = nil
            r.pgid = nil
            actions.append(.finalizeRun(outcome: runOutcome, code: code, signal: signal))
            actions.append(.notify(outcome: outcome))
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
}
