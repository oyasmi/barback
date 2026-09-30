import Foundation
import Testing
@testable import BarbackCore

/// Matrix test per design.md A2 / §8.4: {autorestart×3} × {exit code 0/nonzero/signal} × {startSeconds in/out}.
struct ServiceStateMachineTests {
    func program(autorestart: AutoRestartPolicy, startSeconds: Int = 5, startRetries: Int = 3) -> Program {
        Program(name: "svc", kind: .service, command: "/bin/true", autorestart: autorestart, exitCodes: [0], startSeconds: startSeconds, startRetries: startRetries)
    }

    @Test func startTransitionsToStarting() {
        let (r, actions) = ServiceStateMachine.reduce(runtime: ServiceRuntime(), event: .start(trigger: .manual), config: program(autorestart: .never))
        #expect(r.state == .starting)
        #expect(actions.contains(.spawn(trigger: .manual)))
    }

    @Test func startSecondsElapsedEntersRunning() {
        var r = ServiceRuntime(state: .starting)
        let (r2, _) = ServiceStateMachine.reduce(runtime: r, event: .spawnSucceeded(pid: 1, pgid: 1, procStartTime: 0, at: Date()), config: program(autorestart: .never))
        r = r2
        #expect(r.state == .starting)
        let (r3, _) = ServiceStateMachine.reduce(runtime: r, event: .startSecondsElapsed, config: program(autorestart: .never))
        #expect(r3.state == .running)
    }

    @Test(arguments: [AutoRestartPolicy.never, .unexpected, .always])
    func exitCodeZeroBehavior(_ policy: AutoRestartPolicy) {
        let runtime = ServiceRuntime(state: .running, pid: 1, pgid: 1)
        let (r, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: 0, signal: nil, at: Date()), config: program(autorestart: policy))
        switch policy {
        case .never, .unexpected:
            #expect(r.state == .exited)
        case .always:
            #expect(r.state == .starting)
        }
        #expect(actions.contains(.finalizeRun(outcome: .succeeded, code: 0, signal: nil)))
    }

    @Test(arguments: [AutoRestartPolicy.never, .unexpected, .always])
    func nonZeroExitBehavior(_ policy: AutoRestartPolicy) {
        let runtime = ServiceRuntime(state: .running, pid: 1, pgid: 1)
        let (r, _) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: 1, signal: nil, at: Date()), config: program(autorestart: policy))
        switch policy {
        case .never:
            #expect(r.state == .exited)
        case .unexpected, .always:
            #expect(r.state == .starting)
        }
    }

    @Test(arguments: [AutoRestartPolicy.never, .unexpected, .always])
    func signalExitBehavior(_ policy: AutoRestartPolicy) {
        let runtime = ServiceRuntime(state: .running, pid: 1, pgid: 1)
        let (r, _) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: nil, signal: 9, at: Date()), config: program(autorestart: policy))
        switch policy {
        case .never:
            #expect(r.state == .exited)
        case .unexpected, .always:
            #expect(r.state == .starting)
        }
    }

    // ex-F37: startRetries=N means N *retries* after the initial attempt (matching
    // supervisor's startretries semantics), i.e. N+1 total spawn attempts before FATAL — the
    // old `retryCount + 1 < startRetries` guard made FATAL land one attempt early.
    @Test func startFailureRetriesThenFatal() {
        var runtime = ServiceRuntime(state: .starting)
        let config = program(autorestart: .never, startRetries: 2)

        let (r1, a1) = ServiceStateMachine.reduce(runtime: runtime, event: .spawnFailed(reason: "boom"), config: config)
        #expect(r1.state == .backoff)
        #expect(a1.contains { if case .scheduleBackoffTimer = $0 { return true }; return false })
        runtime = r1

        let (r2, _) = ServiceStateMachine.reduce(runtime: runtime, event: .backoffElapsed, config: config)
        #expect(r2.state == .starting)
        let (r3, _) = ServiceStateMachine.reduce(runtime: r2, event: .spawnFailed(reason: "boom"), config: config)
        #expect(r3.state == .backoff) // 2nd retry still allowed (startRetries=2)
        runtime = r3

        let (r4, _) = ServiceStateMachine.reduce(runtime: runtime, event: .backoffElapsed, config: config)
        let (r5, a5) = ServiceStateMachine.reduce(runtime: r4, event: .spawnFailed(reason: "boom"), config: config)
        #expect(r5.state == .fatal) // 3rd attempt exhausts the 2 retries
        #expect(a5.contains { if case .notify(.enteredFatal) = $0 { return true }; return false })
    }

    @Test func clearFatalReturnsToStopped() {
        let (r, _) = ServiceStateMachine.reduce(runtime: ServiceRuntime(state: .fatal), event: .clearFatal, config: program(autorestart: .never))
        #expect(r.state == .stopped)
    }

    @Test func stopFromRunningSendsSignalAndSchedulesTimer() {
        let runtime = ServiceRuntime(state: .running, pid: 42, pgid: 42)
        let (r, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .stop, config: program(autorestart: .never))
        #expect(r.state == .stopping)
        #expect(actions.contains(.sendSignal(name: "TERM", group: true)))
    }

    @Test func stopTimeoutEscalatesToKill() {
        let runtime = ServiceRuntime(state: .stopping, pid: 42, pgid: 42)
        let (_, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .stopTimerElapsed, config: program(autorestart: .never))
        #expect(actions.contains(.sendKill(pid: 42, pgid: 42, group: true)))
    }

    @Test func stormProtectionForcesFatal() {
        var runtime = ServiceRuntime(state: .running, pid: 1, pgid: 1)
        var config = program(autorestart: .unexpected)
        config.stormMaxRestarts = 2
        config.stormWindowSec = 600
        let (r1, _) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: 1, signal: nil, at: Date()), config: config)
        runtime = ServiceRuntime(state: .running, restartTimestamps: r1.restartTimestamps, pid: 1, pgid: 1)
        let (r2, actions2) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: 1, signal: nil, at: Date()), config: config)
        #expect(r2.state == .fatal)
        #expect(actions2.contains { if case .notify(.enteredFatal) = $0 { return true }; return false })
    }

    @Test func backoffDelayIsBoundedByMax() {
        let delay = ServiceStateMachine.backoffDelay(retryCount: 10, base: 1, max: 60, jitter: 0, random: { 0 })
        #expect(delay == 60)
    }

    // ex-F21: the leader-exited-during-stop group sweep must carry its own pgid, since the
    // runtime this same reduction hands back has already cleared it.
    @Test func stopProcessExitedCarriesPgidForGroupSweep() {
        let runtime = ServiceRuntime(state: .stopping, pid: 42, pgid: 42)
        var config = program(autorestart: .never)
        config.killAsGroup = true
        let (r, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: nil, signal: 15, at: Date()), config: config)
        #expect(r.pid == nil && r.pgid == nil)
        #expect(actions.contains(.sendKill(pid: nil, pgid: 42, group: true)))
    }

    @Test func stopProcessExitedSkipsSweepWhenKillAsGroupDisabled() {
        let runtime = ServiceRuntime(state: .stopping, pid: 42, pgid: 42)
        var config = program(autorestart: .never)
        config.killAsGroup = false
        let (_, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: nil, signal: 15, at: Date()), config: config)
        #expect(!actions.contains { if case .sendKill = $0 { return true }; return false })
    }

    // ex-F14: SIGKILL escalation must key off killAsGroup, not stopAsGroup.
    @Test func stopTimeoutUsesKillAsGroupNotStopAsGroup() {
        let runtime = ServiceRuntime(state: .stopping, pid: 42, pgid: 42)
        var config = program(autorestart: .never)
        config.stopAsGroup = true
        config.killAsGroup = false
        let (_, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .stopTimerElapsed, config: config)
        #expect(actions.contains(.sendKill(pid: 42, pgid: 42, group: false)))
    }

    // ex-F24: `.always` used to spawn forever with no storm protection at all.
    @Test func alwaysPolicyEntersFatalUnderStorm() {
        var config = program(autorestart: .always)
        config.stormMaxRestarts = 2
        config.stormWindowSec = 600
        var runtime = ServiceRuntime(state: .running, pid: 1, pgid: 1)
        let (r1, _) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: 1, signal: nil, at: Date()), config: config)
        #expect(r1.state == .starting)
        runtime = ServiceRuntime(state: .running, restartTimestamps: r1.restartTimestamps, pid: 1, pgid: 1)
        let (r2, actions2) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: 1, signal: nil, at: Date()), config: config)
        #expect(r2.state == .fatal)
        #expect(actions2.contains { if case .notify(.enteredFatal) = $0 { return true }; return false })
    }

    // ex-F29: entering backoff/fatal must clear pid/pgid rather than persist a dead one.
    @Test func enteringBackoffClearsPid() {
        let runtime = ServiceRuntime(state: .starting, pid: 7, pgid: 7)
        let (r, _) = ServiceStateMachine.reduce(runtime: runtime, event: .spawnFailed(reason: "boom"), config: program(autorestart: .never, startRetries: 5))
        #expect(r.state == .backoff)
        #expect(r.pid == nil && r.pgid == nil)
    }

    // ex-F20: restartTimestamps must not accumulate entries outside the storm window forever.
    @Test func restartTimestampsAreConfinedToStormWindow() {
        var config = program(autorestart: .unexpected)
        config.stormWindowSec = 1
        config.stormMaxRestarts = 100
        let stale = ServiceRuntime(state: .running, restartTimestamps: [Date().addingTimeInterval(-10)], pid: 1, pgid: 1)
        let (r, _) = ServiceStateMachine.reduce(runtime: stale, event: .processExited(code: 1, signal: nil, at: Date()), config: config)
        #expect(r.restartTimestamps.count == 1)
    }

    // ex-F30: a failed spawn must finalize its run row — `enterBackoffOrFatal`'s action list
    // used to have no `.finalizeRun` at all, so `ended_at` stayed NULL forever.
    @Test func spawnFailedFinalizesTheRun() {
        let runtime = ServiceRuntime(state: .starting)
        let (_, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .spawnFailed(reason: "no such file"), config: program(autorestart: .never))
        #expect(actions.contains(.finalizeRun(outcome: .failed, code: nil, signal: nil)))
        #expect(actions.contains {
            if case .logEvent(.spawnFailed, _, let detail) = $0 { return detail["reason"] == "no such file" }
            return false
        })
    }

    // ex-F34: an exit must always leave a trace in the event log, code/signal included —
    // this used to be silent for every exit from RUNNING.
    @Test func runningExitLogsProcessExitedWithDetail() {
        let runtime = ServiceRuntime(state: .running, pid: 1, pgid: 1)
        let (_, actions) = ServiceStateMachine.reduce(runtime: runtime, event: .processExited(code: 9, signal: nil, at: Date()), config: program(autorestart: .never))
        #expect(actions.contains {
            if case .logEvent(.processExited, _, let detail) = $0 { return detail["code"] == "9" }
            return false
        })
    }

    // ex-F36: the crash-storm window is keyed off an explicit `now` rather than a `Date()`
    // called deep inside the reducer, so the storm boundary is exactly reproducible.
    @Test func stormWindowRespectsInjectedNow() {
        var config = program(autorestart: .unexpected)
        config.stormWindowSec = 60
        config.stormMaxRestarts = 2
        let anchor = Date(timeIntervalSince1970: 1_000_000)

        let justInside = ServiceRuntime(state: .running, restartTimestamps: [anchor.addingTimeInterval(-59)], pid: 1, pgid: 1)
        let (r1, _) = ServiceStateMachine.reduce(runtime: justInside, event: .processExited(code: 1, signal: nil, at: anchor), config: config, now: anchor)
        #expect(r1.state == .fatal) // both restarts fall inside the 60s window

        let justOutside = ServiceRuntime(state: .running, restartTimestamps: [anchor.addingTimeInterval(-61)], pid: 1, pgid: 1)
        let (r2, _) = ServiceStateMachine.reduce(runtime: justOutside, event: .processExited(code: 1, signal: nil, at: anchor), config: config, now: anchor)
        #expect(r2.state == .starting) // the stale timestamp fell outside the window and was pruned
    }
}
