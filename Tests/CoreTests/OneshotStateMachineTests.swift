import Foundation
import Testing
@testable import BarbackCore

struct OneshotStateMachineTests {
    func program(timeoutSeconds: Int = 0) -> Program {
        Program(name: "job", kind: .oneshot, command: "/bin/true", exitCodes: [0], timeoutSeconds: timeoutSeconds)
    }

    @Test func runTransitionsToRunningAndSpawns() {
        let (r, actions) = OneshotStateMachine.reduce(runtime: OneshotRuntime(), event: .run, config: program())
        #expect(r.state == .running)
        #expect(actions.contains(.spawn))
    }

    @Test func successfulExitReachesSucceeded() {
        let runtime = OneshotRuntime(state: .running, pid: 1)
        let (r, actions) = OneshotStateMachine.reduce(runtime: runtime, event: .processExited(code: 0, signal: nil, at: Date()), config: program())
        #expect(r.state == .succeeded)
        #expect(actions.contains(.finalizeRun(outcome: .succeeded, code: 0, signal: nil)))
    }

    @Test func nonZeroExitReachesFailed() {
        let runtime = OneshotRuntime(state: .running, pid: 1)
        let (r, _) = OneshotStateMachine.reduce(runtime: runtime, event: .processExited(code: 1, signal: nil, at: Date()), config: program())
        #expect(r.state == .failed)
    }

    @Test func timeoutSendsSignalThenMarksTimeout() {
        var runtime = OneshotRuntime(state: .running, pid: 1)
        let config = program(timeoutSeconds: 5)
        let (r1, actions1) = OneshotStateMachine.reduce(runtime: runtime, event: .timeoutElapsed, config: config)
        #expect(r1.timedOut == true)
        #expect(actions1.contains(.sendSignal(name: "TERM", group: true)))
        runtime = r1
        let (r2, _) = OneshotStateMachine.reduce(runtime: runtime, event: .processExited(code: nil, signal: 15, at: Date()), config: config)
        #expect(r2.state == .timeout)
    }

    @Test func cancelMarksCancelledOnExit() {
        var runtime = OneshotRuntime(state: .running, pid: 1)
        let config = program()
        let (r1, _) = OneshotStateMachine.reduce(runtime: runtime, event: .cancel, config: config)
        #expect(r1.stopRequested)
        runtime = r1
        let (r2, _) = OneshotStateMachine.reduce(runtime: runtime, event: .processExited(code: nil, signal: 15, at: Date()), config: config)
        #expect(r2.state == .cancelled)
    }

    @Test func rerunFromTerminalStateWorks() {
        for terminal in [OneshotState.succeeded, .failed, .timeout, .cancelled] {
            let (r, actions) = OneshotStateMachine.reduce(runtime: OneshotRuntime(state: terminal), event: .run, config: program())
            #expect(r.state == .running)
            #expect(actions.contains(.spawn))
        }
    }

    // The `allowConcurrent`-gated second-spawn path used to live here (and in the reducer),
    // but `OneshotRuntime`/`Supervisor.currentRunId` only ever track one pid at a time — a
    // concurrent run silently corrupted the first run's bookkeeping instead of actually
    // tracking two (ex-F12). `Supervisor.dispatchOneshotEvent` now refuses `.run` while
    // already running, unconditionally, so the reducer itself has nothing left to special-case.
    @Test func runWhileRunningIsANoOpForTheReducer() {
        let runtime = OneshotRuntime(state: .running, pid: 1)
        let (r, actions) = OneshotStateMachine.reduce(runtime: runtime, event: .run, config: program())
        #expect(r.state == .running)
        #expect(actions.isEmpty)
    }

    // ex-F32: the completion notification's duration must come from the reducer itself
    // (procStartTime → exit time), never re-derived by the caller after `.finalizeRun` has
    // already cleared its own run-tracking — that ordering used to make every notification
    // read "0.0s" regardless of how long the run actually took.
    @Test func exitNotifiesWithDurationFromProcStartTime() {
        let startedAt: Double = 1_000
        let runtime = OneshotRuntime(state: .running, pid: 1, procStartTime: startedAt)
        let exitAt = Date(timeIntervalSince1970: startedAt + 2.5)
        let (_, actions) = OneshotStateMachine.reduce(runtime: runtime, event: .processExited(code: 0, signal: nil, at: exitAt), config: program())
        var foundDuration: TimeInterval?
        for action in actions {
            if case .notify(_, let duration) = action { foundDuration = duration }
        }
        #expect(foundDuration != nil)
        #expect(abs((foundDuration ?? -1) - 2.5) < 0.001)
    }

    // ex-F34: a one-shot's spawn failure must leave a trace in the event log too, not just
    // a state transition, with the caller's reason attached.
    @Test func spawnFailedLogsReason() {
        let runtime = OneshotRuntime(state: .running)
        let (r, actions) = OneshotStateMachine.reduce(runtime: runtime, event: .spawnFailed(reason: "posix_spawn failed"), config: program())
        #expect(r.state == .failed)
        #expect(actions.contains {
            if case .logEvent(.spawnFailed, _, let detail) = $0 { return detail["reason"] == "posix_spawn failed" }
            return false
        })
    }
}
