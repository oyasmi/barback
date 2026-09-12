import Foundation
import Testing
@testable import BarbackCore

struct OneshotStateMachineTests {
    func program(timeoutSeconds: Int = 0, allowConcurrent: Bool = false) -> Program {
        Program(name: "job", kind: .oneshot, command: "/bin/true", exitCodes: [0], timeoutSeconds: timeoutSeconds, allowConcurrent: allowConcurrent)
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

    @Test func concurrentRunBlockedWithoutAllowConcurrent() {
        let runtime = OneshotRuntime(state: .running, pid: 1)
        let (r, actions) = OneshotStateMachine.reduce(runtime: runtime, event: .run, config: program(allowConcurrent: false))
        // Supervisor is expected to guard concurrency before calling reduce; the pure
        // reducer itself only special-cases the allowConcurrent=true path below.
        #expect(r.state == .running)
        #expect(actions.isEmpty)
    }

    @Test func concurrentRunAllowedSpawnsAgain() {
        let runtime = OneshotRuntime(state: .running, pid: 1)
        let (_, actions) = OneshotStateMachine.reduce(runtime: runtime, event: .run, config: program(allowConcurrent: true))
        #expect(actions.contains(.spawn))
    }
}
