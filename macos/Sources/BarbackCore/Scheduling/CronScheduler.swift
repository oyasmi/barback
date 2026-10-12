import Foundation

/// Core-queue owned. One wall-clock timer for every scheduled command, none while asleep
/// or unconfigured. Deadlines are ephemeral: launch/wake never replay missed occurrences.
final class CronScheduler {
    private struct Entry {
        let expression: CronExpression
        var next: Date?
    }

    private let queue: DispatchQueue
    private let run: (Int64) -> Void
    private var entries: [Int64: Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var suspended = false
    private var stopped = false

    var nextDeadline: Date? { entries.values.compactMap(\.next).min() }

    init(queue: DispatchQueue, run: @escaping (Int64) -> Void) {
        self.queue = queue
        self.run = run
    }

    deinit { timer?.cancel() }

    func update(programs: [Program], after now: Date = Date()) {
        entries.removeAll()
        for program in programs where program.kind == .oneshot && program.enabled {
            guard let text = program.cronExpression, let expression = try? CronExpression(text) else { continue }
            entries[program.id] = Entry(expression: expression, next: expression.nextDate(after: now))
        }
        armTimer()
    }

    func suspend() {
        suspended = true
        cancelTimer()
    }

    func resume(after now: Date = Date()) {
        suspended = false
        recalculate(after: now)
    }

    func recalculate(after now: Date = Date()) {
        for id in entries.keys {
            let next = entries[id]?.expression.nextDate(after: now)
            entries[id]?.next = next
        }
        armTimer()
    }

    func stop() {
        stopped = true
        cancelTimer()
        entries.removeAll()
    }

    /// Also rejects a timer delayed beyond its scheduled minute (queue stall/clock jump).
    /// Sleep cancellation handles even a short sleep within that same minute.
    func fire(at now: Date) {
        guard !suspended, !stopped else { return }
        let due = entries.keys.filter { entries[$0]?.next.map { $0 <= now } == true }.sorted()
        for id in due {
            guard let deadline = entries[id]?.next else { continue }
            let next = entries[id]?.expression.nextDate(after: now)
            entries[id]?.next = next
            if now.timeIntervalSince(deadline) < 60 { run(id) }
        }
        armTimer()
    }

    private func cancelTimer() {
        generation += 1
        timer?.cancel()
        timer = nil
    }

    private func armTimer() {
        cancelTimer()
        guard !suspended, !stopped, let deadline = nextDeadline else { return }
        let token = generation
        let source = DispatchSource.makeTimerSource(queue: queue)
        let seconds = deadline.timeIntervalSince1970
        let wallTime = timespec(tv_sec: Int(seconds), tv_nsec: 0)
        // Fixed 1s leeway: a percentage of a months-away deadline would miss its minute.
        source.schedule(wallDeadline: DispatchWallTime(timespec: wallTime), leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            self.fire(at: Date())
        }
        timer = source
        source.resume()
    }
}
