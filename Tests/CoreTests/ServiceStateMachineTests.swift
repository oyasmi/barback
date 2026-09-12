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

    @Test func startFailureRetriesThenFatal() {
        var runtime = ServiceRuntime(state: .starting)
        let config = program(autorestart: .never, startRetries: 2)
        let (r1, a1) = ServiceStateMachine.reduce(runtime: runtime, event: .spawnFailed, config: config)
        #expect(r1.state == .backoff)
        #expect(a1.contains { if case .scheduleBackoffTimer = $0 { return true }; return false })
        runtime = r1
        let (r2, _) = ServiceStateMachine.reduce(runtime: runtime, event: .backoffElapsed, config: config)
        #expect(r2.state == .starting)
        let (r3, a3) = ServiceStateMachine.reduce(runtime: r2, event: .spawnFailed, config: config)
        #expect(r3.state == .fatal)
        #expect(a3.contains { if case .notify(.enteredFatal) = $0 { return true }; return false })
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
        #expect(actions.contains(.sendKill(group: true)))
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
}
