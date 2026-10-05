import Foundation
import Testing
@testable import BarbackCore

struct CronSchedulerTests {
    private let start = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!

    private func program(_ id: Int64, enabled: Bool = true, kind: ProgramKind = .oneshot) -> Program {
        Program(id: id, name: "job\(id)", kind: kind, enabled: enabled, command: "/bin/true", cronExpression: "* * * * *")
    }

    @Test func sharesDeadlineAndRunsEachOccurrenceOnce() {
        var runs: [Int64] = []
        let scheduler = CronScheduler(queue: DispatchQueue(label: "cron-test")) { runs.append($0) }
        scheduler.update(programs: [program(1), program(2), program(3, enabled: false), program(4, kind: .service)], after: start)
        #expect(scheduler.nextDeadline == start.addingTimeInterval(60))
        scheduler.fire(at: start.addingTimeInterval(59))
        #expect(runs.isEmpty)
        scheduler.fire(at: start.addingTimeInterval(61))
        scheduler.fire(at: start.addingTimeInterval(62))
        #expect(runs == [1, 2])
        #expect(scheduler.nextDeadline == start.addingTimeInterval(120))
    }

    @Test func shortSleepAcrossDeadlineNeverCatchesUp() {
        var runs: [Int64] = []
        let scheduler = CronScheduler(queue: DispatchQueue(label: "cron-test")) { runs.append($0) }
        scheduler.update(programs: [program(1)], after: start)
        scheduler.suspend()
        scheduler.fire(at: start.addingTimeInterval(61)) // Stale callback before wake delivery.
        scheduler.resume(after: start.addingTimeInterval(62))
        scheduler.fire(at: start.addingTimeInterval(63)) // Stale callback after wake delivery.
        #expect(runs.isEmpty)
        #expect(scheduler.nextDeadline == start.addingTimeInterval(120))
        scheduler.fire(at: start.addingTimeInterval(120))
        #expect(runs == [1])
    }

    @Test func longSleepStartupAndClockChangesSkipMissedTimes() {
        var runs: [Int64] = []
        let scheduler = CronScheduler(queue: DispatchQueue(label: "cron-test")) { runs.append($0) }
        scheduler.update(programs: [program(1)], after: start.addingTimeInterval(65))
        #expect(scheduler.nextDeadline == start.addingTimeInterval(120))
        scheduler.suspend()
        scheduler.resume(after: start.addingTimeInterval(3600))
        #expect(scheduler.nextDeadline == start.addingTimeInterval(3660))
        scheduler.recalculate(after: start.addingTimeInterval(7201))
        #expect(scheduler.nextDeadline == start.addingTimeInterval(7260))
        scheduler.fire(at: start.addingTimeInterval(7202))
        #expect(runs.isEmpty)
        scheduler.recalculate(after: start.addingTimeInterval(30))
        #expect(scheduler.nextDeadline == start.addingTimeInterval(60))
    }

    @Test func lateTimerSkipsInsteadOfReplaying() {
        var runs: [Int64] = []
        let scheduler = CronScheduler(queue: DispatchQueue(label: "cron-test")) { runs.append($0) }
        scheduler.update(programs: [program(1)], after: start)
        scheduler.fire(at: start.addingTimeInterval(300))
        #expect(runs.isEmpty)
        #expect(scheduler.nextDeadline == start.addingTimeInterval(360))
    }

    @Test func disableRemoveEditAndStopCancelSchedules() {
        var runs: [Int64] = []
        let scheduler = CronScheduler(queue: DispatchQueue(label: "cron-test")) { runs.append($0) }
        scheduler.update(programs: [program(1)], after: start)
        scheduler.update(programs: [program(1, enabled: false)], after: start)
        #expect(scheduler.nextDeadline == nil)
        scheduler.fire(at: start.addingTimeInterval(60))
        #expect(runs.isEmpty)
        var edited = program(1)
        edited.cronExpression = "*/5 * * * *"
        scheduler.update(programs: [edited], after: start)
        #expect(scheduler.nextDeadline == start.addingTimeInterval(300))
        scheduler.update(programs: [], after: start)
        #expect(scheduler.nextDeadline == nil)
        scheduler.update(programs: [edited], after: start)
        scheduler.stop()
        scheduler.resume(after: start)
        scheduler.update(programs: [program(1)], after: start)
        scheduler.fire(at: start.addingTimeInterval(60))
        #expect(runs.isEmpty)
    }
}
