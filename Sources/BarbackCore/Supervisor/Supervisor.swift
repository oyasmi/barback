import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ProgramSaveError: Error, Sendable, Equatable {
    case validation([ProgramValidationError])
    case other(String)
}

/// The sole holder of mutable managed-process state, running entirely on the serial
/// `barback.core` queue (design.md §2.2). No AppKit/SwiftUI imports here — the UI only
/// ever sees immutable `SupervisorSnapshot`s posted to the main queue.
public final class Supervisor: @unchecked Sendable {
    public let queue = DispatchQueue(label: "barback.core")
    private let store: Store
    private let logsDir: String
    private let exitWatcher: ExitWatcher
    private let appBootId = UUID().uuidString
    private var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment

    private var programs: [Int64: Program] = [:]
    private var serviceRuntimes: [Int64: ServiceRuntime] = [:]
    private var oneshotRuntimes: [Int64: OneshotRuntime] = [:]
    private var currentRunId: [Int64: Int64] = [:]
    private var startTimers: [Int64: DispatchSourceTimer] = [:]
    private var backoffTimers: [Int64: DispatchSourceTimer] = [:]
    private var stopTimers: [Int64: DispatchSourceTimer] = [:]
    private var stopGraceTimers: [Int64: DispatchSourceTimer] = [:]
    private var timeoutTimers: [Int64: DispatchSourceTimer] = [:]
    private var backoffEndDates: [Int64: Date] = [:]
    private var isOwnChild: [Int64: Bool] = [:]
    /// Programs whose runtime-affecting config changed while they were running, so the live
    /// process no longer matches what is on disk (design.md §5 「运行时字段」). Cleared the
    /// moment a fresh process is spawned with the new config.
    private var needsRestartIds: Set<Int64> = []
    private var pendingTerminationHandlers: [@MainActor @Sendable () -> Void] = []
    private var terminationTimeoutTimer: DispatchSourceTimer?
    private var recoveredCount = 0
    /// Programs mid-delete: the row stays in `programs` (so in-flight events still resolve
    /// normally) until the stop it kicked off actually finishes, then `checkPendingDeletion`
    /// runs the completion (design.md §3.7 — deleting a running program must not orphan it).
    private var pendingDeletions: [Int64: () -> Void] = [:]
    private var logRotationTimer: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?
    /// The newest `run` row per program, kept in memory so building a snapshot costs no
    /// queries at all. It used to be one `fetchRuns(limit: 1)` per program *per publish*,
    /// and a batch command like 「全部停止」 publishes once per program — N programs cost
    /// N² queries on the one queue every managed process depends on.
    private var lastRuns: [Int64: RunRecord] = [:]
    /// Set by `publishSnapshot`, cleared by the flush it schedules — see `publishSnapshot`.
    private var snapshotDirty = false
    /// What the UI was last handed, so an action list that ends in several `.publishSnapshot`
    /// steps without actually changing anything doesn't wake the main thread.
    private var lastPublished: SupervisorSnapshot?

    public var onSnapshot: (@MainActor @Sendable (SupervisorSnapshot) -> Void)?
    public var onNotify: (@Sendable (NotificationKind) -> Void)?
    public var onOneshotNotify: (@Sendable (Program, OneshotState, TimeInterval) -> Void)?

    /// `logsDir` is injectable so tests can run against a scratch directory instead of the
    /// real `~/Library/Logs/Barback` — every log path this type hands to `LogManager` is
    /// derived from it (design.md §5.1).
    public init(store: Store, logsDir: String = AppPaths.logsDir) {
        self.store = store
        self.logsDir = logsDir
        self.exitWatcher = ExitWatcher(queue: queue)
    }

    // MARK: - Startup

    /// Loads config, recovers crashed processes, then autostarts (design.md §3.7).
    public func bootstrap() {
        queue.async { [self] in
            baseEnvironment = loadOrCaptureEnvironment()
            do {
                programs = Dictionary(uniqueKeysWithValues: try store.fetchAllPrograms().map { ($0.id, $0) })
            } catch {
                logSelf("加载配置失败：\(error)")
            }
            loadLastRuns()
            recoverFromCrashIfNeeded()
            try? store.insertEvent(EventRecord(level: .info, type: .appStarted))
            autostartServices()
            publishSnapshot()
            scheduleLogRotationCheck()
            scheduleLivenessReconcile()
        }
    }

    /// One query per program, once per launch — from here on the cache is maintained by the
    /// spawn/finalize paths rather than re-read.
    private func loadLastRuns() {
        lastRuns.removeAll()
        for id in programs.keys {
            if let run = (try? store.fetchRuns(programId: id, limit: 1))?.first {
                lastRuns[id] = run
            }
        }
    }

    private func refreshLastRun(programId: Int64) {
        lastRuns[programId] = (try? store.fetchRuns(programId: programId, limit: 1))?.first
    }

    private func loadOrCaptureEnvironment() -> [String: String] {
        if let cached = try? store.getSetting("env_snapshot"), let data = cached.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        let captured = EnvironmentSnapshot.capture()
        if let data = try? JSONEncoder().encode(captured), let json = String(data: data, encoding: .utf8) {
            try? store.setSetting("env_snapshot", json)
        }
        return captured
    }

    public func refreshEnvironmentSnapshot() {
        queue.async { [self] in
            let captured = EnvironmentSnapshot.capture()
            baseEnvironment = captured
            if let data = try? JSONEncoder().encode(captured), let json = String(data: data, encoding: .utf8) {
                try? store.setSetting("env_snapshot", json)
            }
        }
    }

    private func recoverFromCrashIfNeeded() {
        guard let liveRows = try? store.fetchAllLive(), !liveRows.isEmpty else { return }
        for live in liveRows {
            guard let program = programs[live.programId] else {
                try? store.clearLive(programId: live.programId)
                continue
            }
            guard let pid = live.pid, let startTime = live.procStartTime else {
                // Never actually spawned, or already terminal; drop the stale row.
                try? store.clearLive(programId: live.programId)
                continue
            }
            let alive = ProcessHost.verifyAlive(pid: pid, expectedStartTime: startTime)
            if alive {
                adoptSurvivingProcess(program: program, live: live)
                recoveredCount += 1
            } else {
                handleUnknownOutcome(program: program, live: live)
            }
        }
        if recoveredCount > 0 {
            try? store.insertEvent(EventRecord(level: .warn, type: .recoveredFromCrash, detailJSON: "{\"count\":\(recoveredCount)}"))
        }
    }

    private func adoptSurvivingProcess(program: Program, live: LiveRecord) {
        guard let pid = live.pid else { return }
        // `currentRunId` used to only ever get set by `spawnService`/`spawnOneshot` in this
        // same process — an adopted survivor's run row (created by the crashed instance)
        // never got a slot here, so it never got finalized when the process later actually
        // exited: `ended_at` stayed NULL forever, invisible even to "清空历史" (ex-F31).
        if let runId = live.runId {
            currentRunId[program.id] = runId
        }
        isOwnChild[program.id] = false
        exitWatcher.register(pid: pid, isOwnChild: false) { [weak self] status in
            self?.handleProcessExited(programId: program.id, status: status)
        }
        switch program.kind {
        case .service:
            // design.md §3.7 step 3 only promises RUNNING for a survivor that *was* running;
            // one caught mid-STOPPING had a stop already in flight when Barback crashed, and
            // resuming it as RUNNING silently abandoned that request (ex-F42).
            let wasStopping = live.state == ServiceState.stopping.rawValue
            var runtime = ServiceRuntime(
                state: wasStopping ? .stopping : .running,
                pid: live.pid, pgid: live.pgid, procStartTime: live.procStartTime,
                startedAt: live.startedAt.map(Date.init(timeIntervalSince1970:))
            )
            runtime.retryCount = live.retryCount
            runtime.stopRequested = live.stopRequested
            serviceRuntimes[program.id] = runtime
            if wasStopping {
                // The original stop timer died with the crashed process; re-send the signal
                // and restart the wait from scratch rather than leaving it stuck in STOPPING
                // with nothing left to ever escalate it to KILL.
                ProcessHost.signal(pid: pid, pgid: live.pgid, name: program.stopSignal, asGroup: program.stopAsGroup)
                scheduleTimer(\.stopTimers, id: program.id, seconds: Double(program.stopWaitSeconds)) { [weak self] in
                    self?.dispatchServiceEvent(programId: program.id, event: .stopTimerElapsed)
                }
            }
        case .oneshot:
            var runtime = OneshotRuntime(state: .running, pid: live.pid, pgid: live.pgid, procStartTime: live.procStartTime)
            runtime.stopRequested = live.stopRequested
            oneshotRuntimes[program.id] = runtime
            if live.stopRequested, let pid = live.pid {
                // A stop (manual cancel or a timeout that already fired) was in flight when
                // Barback crashed — the original stop timer died with it, exactly like a
                // service's `wasStopping` case just above. Re-send the signal and restart the
                // wait from scratch rather than resuming the timeout budget on a one-shot that
                // was already on its way out (R09).
                ProcessHost.signal(pid: pid, pgid: live.pgid, name: program.stopSignal, asGroup: program.stopAsGroup)
                scheduleTimer(\.stopTimers, id: program.id, seconds: Double(program.stopWaitSeconds)) { [weak self] in
                    self?.dispatchOneshotEvent(programId: program.id, event: .stopTimerElapsed)
                }
            } else if program.timeoutSeconds > 0, let procStartTime = live.procStartTime {
                // design.md §3.7 step 3: a recovered one-shot must resume its timeout, not run
                // forever unwatched — `procStartTime` is the OS's own record of when it
                // actually started, so the remaining budget survives a crash exactly like a
                // normal run's would (ex-F42).
                let elapsed = Date().timeIntervalSince1970 - procStartTime
                let remaining = max(0, Double(program.timeoutSeconds) - elapsed)
                scheduleTimer(\.timeoutTimers, id: program.id, seconds: remaining) { [weak self] in
                    self?.dispatchOneshotEvent(programId: program.id, event: .timeoutElapsed)
                }
            }
        }
        persistLive(programId: program.id)
    }

    private func handleUnknownOutcome(program: Program, live: LiveRecord) {
        try? store.clearLive(programId: program.id)
        if let runId = live.runId {
            // Neither the process nor the previous Barback instance survived to record how
            // this run actually ended — that is exactly what `RunOutcome.unknown` is for
            // (design.md §3.7 step 4/5), rather than leaving `ended_at` NULL forever the way
            // this path used to (ex-F31).
            try? store.finalizeRun(id: runId, endedAt: Date(), exitCode: nil, termSignal: nil, outcome: .unknown)
        }
        switch program.kind {
        case .service:
            // A pending stop request is honored as a clean stop regardless of autorestart —
            // the user (or shutdown) already said "don't keep this running". Otherwise route
            // through the ordinary unexpected-exit path so autorestart/backoff/storm
            // protection apply exactly as if Barback had been watching when it died, instead
            // of leaving an autorestart=.always service sitting STOPPED until someone notices
            // (design.md §3.7 step 5, ex-F42).
            if program.autorestart != .never, !live.stopRequested {
                serviceRuntimes[program.id] = ServiceRuntime(state: .running, retryCount: live.retryCount)
                dispatchServiceEvent(programId: program.id, event: .processExited(code: nil, signal: nil, at: Date()))
            } else {
                serviceRuntimes[program.id] = ServiceRuntime(state: .stopped)
            }
        case .oneshot:
            oneshotRuntimes[program.id] = OneshotRuntime(state: .failed)
        }
    }

    private func autostartServices() {
        let services = programs.values
            .filter { $0.kind == .service && $0.enabled && $0.autostart }
            .sorted(by: Program.priorityAscending)
        for program in services {
            let runtime = serviceRuntimes[program.id] ?? ServiceRuntime()
            guard runtime.state == .stopped || runtime.state == .exited else { continue }
            dispatchServiceEvent(programId: program.id, event: .start(trigger: .autostart))
        }
    }

    // MARK: - Public commands (all hop to core queue)

    public func start(id: Int64) { queue.async { self.dispatchServiceEvent(programId: id, event: .start(trigger: .manual)) } }
    public func stop(id: Int64) {
        queue.async {
            // A later, explicit stop overrides any restart a previous `restart(id:)` queued up
            // behind this program's in-flight stop — otherwise "重启 → 停止" would still spawn
            // a fresh instance the moment the old one finished exiting (design.md §3.5, R08).
            self.pendingRestartAfterStop.remove(id)
            self.dispatchServiceEvent(programId: id, event: .stop)
        }
    }
    public func restart(id: Int64) {
        queue.async { [self] in
            guard let runtime = serviceRuntimes[id] else { return }
            if runtime.state.isActive {
                pendingRestartAfterStop.insert(id)
                dispatchServiceEvent(programId: id, event: .stop)
            } else {
                dispatchServiceEvent(programId: id, event: .start(trigger: .manual))
            }
        }
    }
    public func clearFatal(id: Int64) { queue.async { self.dispatchServiceEvent(programId: id, event: .clearFatal) } }
    public func forceKill(id: Int64) { queue.async { self.dispatchServiceEvent(programId: id, event: .forceKill) } }

    public func startAll() {
        queue.async { [self] in
            for program in programs.values.filter({ $0.kind == .service && $0.enabled }).sorted(by: Program.priorityAscending) {
                dispatchServiceEvent(programId: program.id, event: .start(trigger: .manual))
            }
        }
    }
    public func stopAll(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            for program in programs.values.filter({ $0.kind == .service }).sorted(by: Program.priorityDescending) {
                pendingRestartAfterStop.remove(program.id)
                if serviceRuntimes[program.id]?.state.isActive == true {
                    dispatchServiceEvent(programId: program.id, event: .stop)
                }
            }
            for program in programs.values.filter({ $0.kind == .oneshot }) {
                if oneshotRuntimes[program.id]?.state.isActive == true {
                    dispatchOneshotEvent(programId: program.id, event: .cancel)
                }
            }
            completion?()
        }
    }
    public func restartAll() {
        queue.async { [self] in
            // Only programs actually running: a disabled or manually-stopped service must not
            // be woken up by "restart all", and priority order matters here just as it does
            // for startAll/stopAll (design.md §3.5).
            for program in programs.values
                .filter({ $0.kind == .service })
                .sorted(by: Program.priorityAscending) {
                guard serviceRuntimes[program.id]?.state.isActive == true else { continue }
                restart(id: program.id)
            }
        }
    }

    public func runOneshot(id: Int64) { queue.async { self.dispatchOneshotEvent(programId: id, event: .run) } }
    public func cancelOneshot(id: Int64) { queue.async { self.dispatchOneshotEvent(programId: id, event: .cancel) } }

    private var pendingRestartAfterStop: Set<Int64> = []

    // MARK: - Config CRUD

    public func snapshotProgram(id: Int64, completion: @escaping @Sendable (Program?) -> Void) {
        queue.async { completion(self.programs[id]) }
    }

    public func allPrograms(completion: @escaping @Sendable ([Program]) -> Void) {
        queue.async { completion(Array(self.programs.values).sorted(by: Program.priorityAscending)) }
    }

    public func validateAndSave(_ program: Program, completion: @escaping @Sendable (Result<Program, ProgramSaveError>) -> Void) {
        queue.async { [self] in
            var existing = Set(programs.values.map(\.name))
            if program.id != 0 { existing.remove(programs[program.id]?.name ?? "") }
            // The same PATH `spawnService`/`spawnOneshot` will actually use, not this
            // process's own — otherwise "找不到可执行文件" can disagree with what
            // `posix_spawn` finds in either direction (ex-F41).
            let errors = ProgramValidator.validate(program, existingNames: existing, pathEnv: mergedEnvironment(for: program)["PATH"])
            guard errors.isEmpty else {
                completion(.failure(.validation(errors)))
                return
            }
            do {
                var saved = program
                if saved.id == 0 {
                    // A "new" draft can be a duplicate of an existing program (design.md §6.3
                    // 「复制」) carrying its source's lifetime run count straight into what is
                    // about to become an unrelated row — reset it here, at the write boundary,
                    // rather than trusting every draft-producing UI path to have done it (R11).
                    saved.runTotal = 0
                    let id = try store.insertProgram(saved)
                    saved.id = id
                    programs[id] = saved
                    if saved.kind == .service {
                        serviceRuntimes[id] = ServiceRuntime()
                    } else {
                        oneshotRuntimes[id] = OneshotRuntime()
                    }
                } else {
                    let old = programs[saved.id]
                    // `store.updateProgram` already excludes `run_total` from the write so the
                    // database's lifetime counter can't be rolled back by a stale draft — but
                    // without this, the in-memory cache below still got overwritten with
                    // whatever `runTotal`/`createdAt` the draft happened to carry from whenever
                    // the config window opened it, so a run completing (and bumping the real
                    // counter) while the window was open could make the panel's count jump
                    // backwards the moment the draft was saved (R11).
                    if let old {
                        saved.runTotal = old.runTotal
                        saved.createdAt = old.createdAt
                    }
                    try store.updateProgram(saved)
                    programs[saved.id] = saved
                    if let old, runtimeFieldsChanged(old, saved), isRunning(saved.id) {
                        needsRestartIds.insert(saved.id)
                    }
                    // The default log path is derived from the name, so without this a rename
                    // silently abandoned the program's whole log history and started a new,
                    // empty file (design.md §4).
                    if let old, old.name != saved.name, saved.kind == .service,
                       saved.logPath == nil, old.logPath == nil {
                        LogManager.renameServiceLogs(oldName: old.name, newName: saved.name, logsDir: logsDir)
                    }
                }
                try? backupConfig()
                try? store.insertEvent(EventRecord(level: .info, programId: saved.id, type: .configChanged))
                completion(.success(saved))
                publishSnapshot()
            } catch {
                completion(.failure(.other("\(error)")))
            }
        }
    }

    /// Rewrites `priority` to match a drag-reordered sidebar. Deliberately skips
    /// `ProgramValidator`: reordering must not be blocked by a field error in some other
    /// program the user never touched.
    public func reorderPrograms(orderedIds: [Int64], completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            for (index, id) in orderedIds.enumerated() {
                let newPriority = (index + 1) * 10
                guard var program = programs[id], program.priority != newPriority else { continue }
                program.priority = newPriority
                program.updatedAt = Date()
                try? store.updateProgram(program)
                programs[id] = program
            }
            try? backupConfig()
            publishSnapshot()
            completion()
        }
    }

    /// Deleting a running program used to fire off a `.stop` and immediately drop it from the
    /// store and every dictionary while the process was still alive: the stop-timeout escalation
    /// then found `programs[id]` gone and gave up, leaking the process (design.md §3.7). Now the
    /// row is only actually removed once its stop has really completed.
    public func deleteProgram(id: Int64, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            // Delete outranks any restart a previous `restart(id:)` queued behind this
            // program's in-flight stop (design.md §3.5, R08) — without this, "重启 → 删除"
            // could spawn a brand-new instance of a program that is about to be removed.
            pendingRestartAfterStop.remove(id)
            let serviceActive = serviceRuntimes[id]?.state.isActive == true
            let oneshotActive = oneshotRuntimes[id]?.state.isActive == true
            guard serviceActive || oneshotActive else {
                finishDelete(id: id, completion: completion)
                return
            }
            pendingDeletions[id] = completion
            if serviceActive {
                dispatchServiceEvent(programId: id, event: .stop)
            }
            if oneshotActive {
                dispatchOneshotEvent(programId: id, event: .cancel)
            }
        }
    }

    private func finishDelete(id: Int64, completion: (() -> Void)?) {
        // Defensive: in the ordinary stop-then-delete path the exit source has already
        // self-unregistered by the time `finishDelete` runs (`ExitWatcher.handleExit`
        // unregisters before invoking its callback), but the stop-grace force-clear path can
        // reach here while the real (already-SIGKILLed) process's NOTE_EXIT is still pending
        // — dropping the program from `programs` shouldn't leave a kqueue source outliving it
        // even though `handleProcessExited`'s own guard makes that harmless today (ex-F45).
        if let pid = serviceRuntimes[id]?.pid ?? oneshotRuntimes[id]?.pid {
            exitWatcher.unregister(pid: pid)
        }
        // Collected before the row goes away: `ON DELETE CASCADE` drops the `run` rows, and
        // with them the only record of where each run's output file lives — the files
        // themselves used to stay in `runs/` forever with nothing left pointing at them.
        let runLogPaths = (try? store.fetchRunLogPaths(programId: id)) ?? []
        let deletedName = programs[id]?.name
        let usedDefaultLogPath = programs[id]?.logPath == nil
        try? store.deleteProgram(id: id)
        removeRunOutputFiles(runLogPaths)
        if let deletedName, usedDefaultLogPath {
            LogManager.removeServiceLogs(name: deletedName, logsDir: logsDir)
        }
        programs.removeValue(forKey: id)
        lastRuns.removeValue(forKey: id)
        serviceRuntimes.removeValue(forKey: id)
        oneshotRuntimes.removeValue(forKey: id)
        needsRestartIds.remove(id)
        currentRunId.removeValue(forKey: id)
        isOwnChild.removeValue(forKey: id)
        backoffEndDates.removeValue(forKey: id)
        pendingRestartAfterStop.remove(id)
        cancelTimer(\.startTimers, id: id)
        cancelTimer(\.backoffTimers, id: id)
        cancelTimer(\.stopTimers, id: id)
        cancelTimer(\.stopGraceTimers, id: id)
        cancelTimer(\.timeoutTimers, id: id)
        // Save and reorder backed up the config on every commit but delete never did — a user
        // who only ever deletes programs (never edits or reorders) could have zero config
        // backups to fall back on if the database were then lost (design.md §8.1, R15).
        try? backupConfig()
        publishSnapshot()
        completion?()
    }

    private func checkPendingDeletion(programId: Int64) {
        guard let completion = pendingDeletions[programId] else { return }
        let stillActive = serviceRuntimes[programId]?.state.isActive == true || oneshotRuntimes[programId]?.state.isActive == true
        guard !stillActive else { return }
        pendingDeletions.removeValue(forKey: programId)
        finishDelete(id: programId, completion: completion)
    }

    private func isRunning(_ id: Int64) -> Bool {
        serviceRuntimes[id]?.state.isActive == true || oneshotRuntimes[id]?.state.isActive == true
    }

    private func runtimeFieldsChanged(_ a: Program, _ b: Program) -> Bool {
        Program.runtimeFieldsDiffer(a, b)
    }

    private func backupConfig() throws {
        let all = Array(programs.values)
        let data = try JSONEncoder().encode(all)
        try store.writeConfigBackup(data)
    }

    // MARK: - Import

    public func importPrograms(_ drafts: [Program], completion: @escaping @Sendable ([Program]) -> Void) {
        queue.async { [self] in
            var saved: [Program] = []
            for var draft in drafts {
                var existing = Set(programs.values.map(\.name))
                var name = draft.name
                var suffix = 2
                // `draft.name` is already ≤64 chars (`Program.namePattern`), but appending
                // `-N` to a name already at that limit used to push it past it — silently
                // saving a program whose own name failed the validator it was never actually
                // run through here (R12). Truncating the base before appending keeps the
                // final result within bounds without changing the suffix itself.
                while existing.contains(name) {
                    let suffixText = "-\(suffix)"
                    let base = String(draft.name.prefix(64 - suffixText.count))
                    name = base + suffixText
                    suffix += 1
                }
                draft.name = name
                existing.insert(name)
                if let id = try? store.insertProgram(draft) {
                    draft.id = id
                    programs[id] = draft
                    if draft.kind == .service {
                        serviceRuntimes[id] = ServiceRuntime()
                    } else {
                        oneshotRuntimes[id] = OneshotRuntime()
                    }
                    saved.append(draft)
                }
            }
            try? store.insertEvent(EventRecord(level: .info, type: .imported, detailJSON: "{\"count\":\(saved.count)}"))
            // A user who builds their whole config through import (never touching the form or
            // sidebar reorder, the only two places that used to call this) could end up with
            // zero config backups — the one mechanism that survives a corrupt/lost database
            // (design.md §8.1, R15).
            if !saved.isEmpty { try? backupConfig() }
            publishSnapshot()
            completion(saved)
        }
    }

    // MARK: - Service state machine wiring

    private func dispatchServiceEvent(programId: Int64, event: ServiceEvent) {
        guard let program = programs[programId] else { return }
        let runtime = serviceRuntimes[programId] ?? ServiceRuntime()
        let (newRuntime, actions) = ServiceStateMachine.reduce(runtime: runtime, event: event, config: program)
        serviceRuntimes[programId] = newRuntime
        for action in actions {
            perform(action, programId: programId, program: program)
        }
    }

    private func perform(_ action: ServiceAction, programId: Int64, program: Program) {
        switch action {
        case .spawn(let trigger):
            spawnService(program: program, trigger: trigger)
        case .scheduleStartTimer(let seconds):
            scheduleTimer(\.startTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchServiceEvent(programId: programId, event: .startSecondsElapsed)
            }
        case .cancelStartTimer:
            cancelTimer(\.startTimers, id: programId)
        case .scheduleBackoffTimer(let seconds):
            backoffEndDates[programId] = Date().addingTimeInterval(seconds)
            scheduleTimer(\.backoffTimers, id: programId, seconds: seconds) { [weak self] in
                self?.backoffEndDates.removeValue(forKey: programId)
                self?.dispatchServiceEvent(programId: programId, event: .backoffElapsed)
            }
        case .cancelBackoffTimer:
            cancelTimer(\.backoffTimers, id: programId)
            backoffEndDates.removeValue(forKey: programId)
        case .sendSignal(let name, let group):
            if let runtime = serviceRuntimes[programId], let pid = runtime.pid {
                ProcessHost.signal(pid: pid, pgid: runtime.pgid, name: name, asGroup: group)
            }
        case .scheduleStopTimer(let seconds):
            scheduleTimer(\.stopTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchServiceEvent(programId: programId, event: .stopTimerElapsed)
            }
        case .cancelStopTimer:
            cancelTimer(\.stopTimers, id: programId)
        case .sendKill(let pid, let pgid, let group):
            // `pid`/`pgid` travel with the action rather than being re-read from
            // `serviceRuntimes` here, because some transitions (stop's processExited) clear
            // the runtime's pid in the very same reduction that emits this action — reading
            // it back afterwards would always see nil (design.md §3.3, ex-F21).
            //
            // `pid` is deliberately nil for the group-sweep-only case (stop's processExited,
            // §3.3): the leader already exited, and the only thing left to kill is whatever
            // it forked into the group. That still requires an actual `kill(-pgid, SIGKILL)`
            // — without this branch the sweep was silently skipped whenever `pid` was nil,
            // leaving TERM-ignoring descendants running with the panel showing STOPPED.
            if let pid {
                ProcessHost.sendKill(pid: pid, pgid: pgid, asGroup: group)
            } else if group, let pgid {
                ProcessHost.sendKill(pid: pgid, pgid: pgid, asGroup: true)
            }
        case .scheduleStopGrace(let seconds):
            scheduleTimer(\.stopGraceTimers, id: programId, seconds: seconds) { [weak self] in
                guard let self else { return }
                if let runtime = self.serviceRuntimes[programId], runtime.state == .stopping {
                    // Timed out even after KILL; force-clear so we don't get stuck.
                    var r = runtime
                    r.state = .stopped
                    r.pid = nil
                    self.serviceRuntimes[programId] = r
                    // This bypasses the reducer entirely, so — like the two follow-ups noted
                    // below — it also has to repeat `.finalizeRun` itself: without it the run
                    // row `spawnService` inserted stayed `ended_at IS NULL` forever, the same
                    // orphaned-row shape as ex-F30/ex-F31 (R14).
                    if let runId = self.currentRunId[programId] {
                        self.finalizeRun(programId: programId, runId: runId, outcome: .cancelled, code: nil, signal: nil)
                    }
                    self.persistLive(programId: programId)
                    self.publishSnapshot()
                    // This settles the runtime to STOPPED exactly like a normal
                    // `.publishSnapshot` action would (see `perform(_:programId:program:)`
                    // above) — it just does so from a handler that bypasses the reducer, so
                    // it has to repeat that action's other two follow-ups too. Missing
                    // `checkRestartAfterStop` here left "重启" on a SIGTERM-ignoring program
                    // permanently stuck: stopped, killed, and never restarted, with a
                    // `pendingRestartAfterStop` entry that would then wrongly fire on some
                    // *later* unrelated stop (ex-F39).
                    self.checkRestartAfterStop(programId: programId)
                    self.runPendingTerminationIfIdle()
                    self.checkPendingDeletion(programId: programId)
                }
            }
        case .cancelStopGrace:
            cancelTimer(\.stopGraceTimers, id: programId)
        case .persistLive:
            persistLive(programId: programId)
        case .publishSnapshot:
            publishSnapshot()
            checkRestartAfterStop(programId: programId)
            runPendingTerminationIfIdle()
            checkPendingDeletion(programId: programId)
        case .notify(let kind):
            onNotify?(kind)
        case .logEvent(let type, let level, let detail):
            let json = (try? JSONSerialization.data(withJSONObject: detail)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try? store.insertEvent(EventRecord(level: level, programId: programId, type: type, detailJSON: json))
        case .finalizeRun(let outcome, let code, let signal):
            if let runId = currentRunId[programId] {
                finalizeRun(programId: programId, runId: runId, outcome: outcome, code: code, signal: signal)
            }
            // A service's run rows never had a trim call at all before this — an
            // `autorestart=always` service that flaps for a year would write unbounded rows
            // (design.md §3.4, ex-F09); trimming right where each run finalizes ties it to
            // exactly one point per run, rather than every snapshot publish in between.
            trimHistoryIfNeeded(program: program)
        }
    }

    private func checkRestartAfterStop(programId: Int64) {
        guard pendingRestartAfterStop.contains(programId) else { return }
        guard let runtime = serviceRuntimes[programId], runtime.state == .stopped else { return }
        pendingRestartAfterStop.remove(programId)
        dispatchServiceEvent(programId: programId, event: .start(trigger: .manual))
    }

    private func spawnService(program: Program, trigger: RunTrigger) {
        // Whatever we are about to launch uses the saved config, so the drift is gone.
        needsRestartIds.remove(program.id)
        // Closed on every exit from this scope, success or failure alike — `logFDs` used to
        // be a `let` local only reachable from the success path, so a `ProcessHost.spawn`
        // throw after the logs were already opened leaked both fds every single time the
        // service failed to start (ex-F30).
        var logFDs: LogFDs?
        defer { if let logFDs { LogManager.closeFDs(logFDs) } }
        do {
            if program.logRotatePolicy == .onRestart {
                let paths = LogManager.serviceLogPaths(
                    name: program.name, logsDir: logsDir, mergeStderr: program.logMergeStderr,
                    explicitOutPath: program.logPath, explicitErrPath: program.logStderrPath
                )
                _ = try? LogManager.rotateIfNeeded(path: paths.out, maxBytes: program.logMaxBytes, backups: program.logBackups, force: true)
                if paths.err != paths.out {
                    _ = try? LogManager.rotateIfNeeded(path: paths.err, maxBytes: program.logMaxBytes, backups: program.logBackups, force: true)
                }
            }
            let fds = try LogManager.openServiceLogs(
                name: program.name,
                logsDir: logsDir,
                mergeStderr: program.logMergeStderr,
                explicitOutPath: program.logPath,
                explicitErrPath: program.logStderrPath
            )
            logFDs = fds
            var run = RunRecord(programId: program.id, trigger: trigger, logPath: fds.outPath)
            run.id = try store.insertRun(run)
            lastRuns[program.id] = run
            currentRunId[program.id] = run.id
            if var p = programs[program.id] { p.runTotal += 1; programs[program.id] = p }
            let env = mergedEnvironment(for: program)
            let spawned = try ProcessHost.spawn(
                command: program.command,
                useShell: program.useShell,
                directory: program.directory,
                environment: env,
                outFD: fds.outFD,
                errFD: fds.errFD
            )
            isOwnChild[program.id] = true
            exitWatcher.register(pid: spawned.pid, isOwnChild: true) { [weak self] status in
                self?.handleProcessExited(programId: program.id, status: status)
            }
            dispatchServiceEvent(programId: program.id, event: .spawnSucceeded(pid: spawned.pid, pgid: spawned.pgid, procStartTime: spawned.startTime, at: Date()))
        } catch {
            // `currentRunId` is deliberately left alone here — `.spawnFailed` finalizes the
            // run through the reducer's own `.finalizeRun` action now, and clearing it early
            // (as this used to) made that action's `perform(.finalizeRun)` lookup always miss,
            // leaving the run row's `ended_at` NULL forever (ex-F30).
            let reason = describe(error)
            logSelf("启动失败 \(program.name): \(reason)")
            dispatchServiceEvent(programId: program.id, event: .spawnFailed(reason: reason))
        }
    }

    /// Prefers `LocalizedError.errorDescription` (the Chinese messages `ProcessHostError`/
    /// `LogManagerError`/`SQLiteError` all define) over `"\(error)"`'s raw enum-case dump, so
    /// the reason that ends up in the event log and `logSelf` is something a user can read
    /// rather than e.g. `posixSpawnFailed(2)`.
    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private func handleProcessExited(programId: Int64, status: ExitStatus) {
        guard let program = programs[programId] else { return }
        if program.kind == .service {
            dispatchServiceEvent(programId: programId, event: .processExited(code: status.code, signal: status.signal, at: Date()))
        } else {
            dispatchOneshotEvent(programId: programId, event: .processExited(code: status.code, signal: status.signal, at: Date()))
        }
    }

    private func persistLive(programId: Int64) {
        let state: String
        let pid: Int32?
        let pgid: Int32?
        let procStartTime: Double?
        let startedAt: Double?
        let retryCount: Int
        let stopRequested: Bool

        if let runtime = serviceRuntimes[programId] {
            state = runtime.state.rawValue
            pid = runtime.pid
            pgid = runtime.pgid
            procStartTime = runtime.procStartTime
            startedAt = runtime.startedAt?.timeIntervalSince1970
            retryCount = runtime.retryCount
            stopRequested = runtime.stopRequested
            if !runtime.state.isActive {
                try? store.clearLive(programId: programId)
                return
            }
        } else if let runtime = oneshotRuntimes[programId] {
            state = runtime.state.rawValue
            pid = runtime.pid
            pgid = runtime.pgid
            procStartTime = runtime.procStartTime
            startedAt = nil
            retryCount = 0
            stopRequested = runtime.stopRequested
            if !runtime.state.isActive {
                try? store.clearLive(programId: programId)
                return
            }
        } else {
            return
        }

        let live = LiveRecord(
            programId: programId, appBootId: appBootId, state: state, pid: pid, pgid: pgid,
            procStartTime: procStartTime, startedAt: startedAt, retryCount: retryCount,
            stopRequested: stopRequested, runId: currentRunId[programId]
        )
        try? store.upsertLive(live)
    }

    // MARK: - Oneshot state machine wiring

    private func dispatchOneshotEvent(programId: Int64, event: OneshotEvent) {
        guard let program = programs[programId] else { return }
        let runtime = oneshotRuntimes[programId] ?? OneshotRuntime()
        // A second run while one is already in flight was only ever safe on paper: the
        // runtime/currentRunId bookkeeping is single-slot, so a concurrent run silently
        // corrupted the first one's tracking (design.md §3.4, ex-F12). Always serialize.
        if case .run = event, runtime.state == .running { return }
        let (newRuntime, actions) = OneshotStateMachine.reduce(runtime: runtime, event: event, config: program)
        oneshotRuntimes[programId] = newRuntime
        for action in actions {
            perform(action, programId: programId, program: program)
        }
    }

    private func perform(_ action: OneshotAction, programId: Int64, program: Program) {
        switch action {
        case .spawn:
            spawnOneshot(program: program)
        case .sendSignal(let name, let group):
            if let runtime = oneshotRuntimes[programId], let pid = runtime.pid {
                ProcessHost.signal(pid: pid, pgid: runtime.pgid, name: name, asGroup: group)
            }
        case .scheduleStopTimer(let seconds):
            scheduleTimer(\.stopTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchOneshotEvent(programId: programId, event: .stopTimerElapsed)
            }
        case .cancelStopTimer:
            cancelTimer(\.stopTimers, id: programId)
        case .scheduleTimeoutTimer(let seconds):
            scheduleTimer(\.timeoutTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchOneshotEvent(programId: programId, event: .timeoutElapsed)
            }
        case .cancelTimeoutTimer:
            cancelTimer(\.timeoutTimers, id: programId)
        case .sendKill(let group):
            if let runtime = oneshotRuntimes[programId], let pid = runtime.pid {
                ProcessHost.sendKill(pid: pid, pgid: runtime.pgid, asGroup: group)
            }
        case .persistLive:
            persistLive(programId: programId)
        case .publishSnapshot:
            publishSnapshot()
            trimHistoryIfNeeded(program: program)
            runPendingTerminationIfIdle()
            checkPendingDeletion(programId: programId)
        case .notify(let outcome, let duration):
            // `duration` now travels with the action, computed by the reducer itself from
            // `procStartTime` — no more reading it back from `Store` after `.finalizeRun` (see
            // below) has already cleared `currentRunId`, which used to make this lookup miss
            // every single time and every completion notification read "0.0s" (ex-F32).
            onOneshotNotify?(program, outcome, duration)
        case .logEvent(let type, let level, let detail):
            let json = (try? JSONSerialization.data(withJSONObject: detail)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try? store.insertEvent(EventRecord(level: level, programId: programId, type: type, detailJSON: json))
        case .finalizeRun(let outcome, let code, let signal):
            if let runId = currentRunId[programId] {
                finalizeRun(programId: programId, runId: runId, outcome: outcome, code: code, signal: signal)
            }
        }
    }

    /// Writes the run's ending to the store and mirrors it into `lastRuns`, so the next
    /// snapshot reports the outcome without going back to SQLite for it.
    private func finalizeRun(programId: Int64, runId: Int64, outcome: RunOutcome, code: Int32?, signal: Int32?) {
        let endedAt = Date()
        try? store.finalizeRun(id: runId, endedAt: endedAt, exitCode: code, termSignal: signal, outcome: outcome)
        currentRunId.removeValue(forKey: programId)
        if var cached = lastRuns[programId], cached.id == runId {
            cached.endedAt = endedAt
            cached.exitCode = code
            cached.termSignal = signal
            cached.outcome = outcome
            lastRuns[programId] = cached
        } else {
            // Adopted survivor: the row was written by the instance that crashed, so there is
            // nothing cached to patch (design.md §3.7).
            refreshLastRun(programId: programId)
        }
    }

    private func spawnOneshot(program: Program) {
        needsRestartIds.remove(program.id)
        // Same fd-leak/early-clear hazards as `spawnService` — see the comments there (ex-F30).
        var logFDs: LogFDs?
        defer { if let logFDs { LogManager.closeFDs(logFDs) } }
        do {
            var run = RunRecord(programId: program.id, trigger: .manual)
            run.id = try store.insertRun(run)
            // Set as soon as the row exists, not after `openRunLog` below also succeeds — a
            // log-open failure (unwritable runs dir, out of fds) used to throw before this ran,
            // so `.spawnFailed`'s `.finalizeRun` action (dispatched from the `catch` below)
            // found no `currentRunId` entry to finalize and the row just inserted sat with
            // `ended_at IS NULL` forever, invisible even to "清空历史" (R14, same shape as
            // ex-F30's fd-leak fix just below).
            lastRuns[program.id] = run
            currentRunId[program.id] = run.id
            // The output file is named after the run id, so the path only exists once the row
            // does — and nothing used to write it back. Every one-shot run row therefore had
            // `log_path = NULL`, which is what 「查看本次输出」 and the history window's
            // 「查看输出」 both read: they showed an empty/absent file for output that was
            // sitting on disk the whole time (design.md §3.4, ONE-4).
            let fds = try LogManager.openRunLog(name: program.name, runId: run.id, logsDir: logsDir)
            logFDs = fds
            run.logPath = fds.outPath
            try? store.setRunLogPath(id: run.id, path: fds.outPath)
            lastRuns[program.id] = run
            if var p = programs[program.id] { p.runTotal += 1; programs[program.id] = p }
            let env = mergedEnvironment(for: program)
            let spawned = try ProcessHost.spawn(
                command: program.command,
                useShell: program.useShell,
                directory: program.directory,
                environment: env,
                outFD: fds.outFD,
                errFD: fds.errFD
            )
            isOwnChild[program.id] = true
            exitWatcher.register(pid: spawned.pid, isOwnChild: true) { [weak self] status in
                self?.handleProcessExited(programId: program.id, status: status)
            }
            dispatchOneshotEvent(programId: program.id, event: .spawnSucceeded(pid: spawned.pid, pgid: spawned.pgid, procStartTime: spawned.startTime, at: Date()))
        } catch {
            dispatchOneshotEvent(programId: program.id, event: .spawnFailed(reason: describe(error)))
        }
    }

    private func trimHistoryIfNeeded(program: Program) {
        guard let paths = try? store.trimRunHistory(programId: program.id, historyLimit: program.historyLimit) else { return }
        removeRunOutputFiles(paths)
    }

    /// Deletes the output files a set of discarded run rows owned — and *only* those.
    ///
    /// A one-shot's run row owns its file outright (`runs/<name>-<runId>.log`). A service's
    /// rows do not: every one of them carries the same path, the program's single
    /// `programs/<name>.out.log`. Deleting by `log_path` therefore meant that trimming a
    /// service's history down to `historyLimit` unlinked the live log file out from under the
    /// running process — which, still holding the fd, carried on writing into an inode with no
    /// name, while the log window showed an empty file. The `runs/` prefix is what separates
    /// the two, and it also keeps this from ever touching a user-chosen explicit `logPath`.
    private func removeRunOutputFiles(_ paths: [String]) {
        let runsDir = (logsDir as NSString).appendingPathComponent("runs") + "/"
        for path in paths where path.hasPrefix(runsDir) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Environment

    private func mergedEnvironment(for program: Program) -> [String: String] {
        var env = baseEnvironment
        for (key, value) in program.environment {
            env[key] = value.value
        }
        env["BARBACK_PROGRAM_NAME"] = program.name
        return env
    }

    // MARK: - Timers (leeway per design.md §2.2)

    /// Keyed by a `ReferenceWritableKeyPath` into `self` rather than `inout`, so the fired
    /// timer's own completion handler can remove *itself* from the exact dict it was stored
    /// in. The previous `clearTimer(id:)` had no way to know which of five dictionaries to
    /// touch and was a permanent no-op — every timer that ever fired stayed in its dict
    /// forever (design.md §2.2, ex-F20).
    private func scheduleTimer(_ keyPath: ReferenceWritableKeyPath<Supervisor, [Int64: DispatchSourceTimer]>, id: Int64, seconds: Double, handler: @escaping () -> Void) {
        self[keyPath: keyPath][id]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let leeway = max(seconds * 0.1, 1.0)
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(Int(leeway * 1000)))
        timer.setEventHandler { [weak self] in
            self?[keyPath: keyPath].removeValue(forKey: id)
            handler()
        }
        self[keyPath: keyPath][id] = timer
        timer.resume()
    }

    private func cancelTimer(_ keyPath: ReferenceWritableKeyPath<Supervisor, [Int64: DispatchSourceTimer]>, id: Int64) {
        self[keyPath: keyPath][id]?.cancel()
        self[keyPath: keyPath].removeValue(forKey: id)
    }

    // MARK: - Snapshot publishing

    /// Marks the snapshot stale and schedules exactly one flush.
    ///
    /// A single reduction emits `.publishSnapshot` more than once, and a batch command
    /// (`startAll`/`stopAll`/termination) runs a whole reduction per program — all of that
    /// used to build a full snapshot and hop to the main thread each time. Because the core
    /// queue is serial, work enqueued here always runs after the current block has finished
    /// draining, so one `queue.async` collapses the entire batch into a single publish.
    private func publishSnapshot() {
        guard !snapshotDirty else { return }
        snapshotDirty = true
        queue.async { [self] in
            guard snapshotDirty else { return }
            snapshotDirty = false
            deliverSnapshot(buildSnapshot())
        }
    }

    private func deliverSnapshot(_ snapshot: SupervisorSnapshot) {
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        let callback = onSnapshot
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(snapshot) } }
    }

    /// Reads the current state of the world. Core-queue only.
    public func fetchSnapshot(completion: @escaping @Sendable (SupervisorSnapshot) -> Void) {
        queue.async { [self] in completion(buildSnapshot()) }
    }

    /// Clears 「上次异常退出，已接管 N 项」 once the user has seen it — design.md §3.7 step 7
    /// promises that notice appears *once*, not on every panel open for the rest of the
    /// session.
    public func dismissRecoveryNotice() {
        queue.async { [self] in
            guard recoveredCount > 0 else { return }
            recoveredCount = 0
            publishSnapshot()
        }
    }

    private func buildSnapshot() -> SupervisorSnapshot {
        let snapshotPrograms: [ProgramSnapshot] = programs.values.map { program in
            let lastRun = lastRuns[program.id]
            // `program.runTotal` is a column read straight off the in-memory `Program`, kept
            // current by the spawn path — no query here at all. Used to be a
            // `fetchRuns(limit: 100000)` per program per snapshot publish, which happens
            // several times per start/stop and grows without bound as history accumulates
            // (design.md §3.4, ex-F15/F07).
            let runCount = program.runTotal
            let drifted = needsRestartIds.contains(program.id)
            if program.kind == .service {
                let runtime = serviceRuntimes[program.id] ?? ServiceRuntime()
                let remaining = backoffEndDates[program.id].map { max(0, $0.timeIntervalSinceNow) }
                return ProgramSnapshot(
                    program: program, serviceState: runtime.state, oneshotState: nil,
                    pid: runtime.pid, startedAt: runtime.startedAt, retryCount: runtime.retryCount,
                    backoffRemaining: remaining, lastRun: lastRun, runCount: runCount,
                    // Only worth saying while a process is actually running the old config.
                    needsRestart: drifted && runtime.state.isActive
                )
            } else {
                let runtime = oneshotRuntimes[program.id] ?? OneshotRuntime()
                return ProgramSnapshot(
                    program: program, serviceState: nil, oneshotState: runtime.state,
                    pid: runtime.pid, startedAt: nil, retryCount: 0,
                    backoffRemaining: nil, lastRun: lastRun, runCount: runCount,
                    needsRestart: drifted && runtime.state.isActive
                )
            }
        }.sorted { Program.priorityAscending($0.program, $1.program) }
        return SupervisorSnapshot(programs: snapshotPrograms, recoveredCount: recoveredCount)
    }

    // MARK: - Sleep/wake reconciliation (design.md §3.8)

    /// Shared by wake, the periodic safety-net timer, and panel-open: re-verifies every
    /// active pid against kqueue's view of the world. kqueue's `NOTE_EXIT` almost never
    /// misses, but `adoptSurvivingProcess` has a real (if narrow) window where a crash-adopted
    /// orphan can exit between `verifyAlive` and `exitWatcher.register` with no callback ever
    /// firing for it — this is the backstop that catches that (design.md §3.2/§3.7, ex-F25).
    private func reconcileLiveness() {
        for (id, runtime) in serviceRuntimes where runtime.state.isActive {
            guard let pid = runtime.pid, let startTime = runtime.procStartTime else { continue }
            if !ProcessHost.verifyAlive(pid: pid, expectedStartTime: startTime) {
                reapDeadPid(pid)
                dispatchServiceEvent(programId: id, event: .processExited(code: nil, signal: nil, at: Date()))
            }
        }
        for (id, runtime) in oneshotRuntimes where runtime.state.isActive {
            guard let pid = runtime.pid, let startTime = runtime.procStartTime else { continue }
            if !ProcessHost.verifyAlive(pid: pid, expectedStartTime: startTime) {
                reapDeadPid(pid)
                dispatchOneshotEvent(programId: id, event: .processExited(code: nil, signal: nil, at: Date()))
            }
        }
    }

    /// This is the same conclusion `ExitWatcher`'s own kqueue callback would have reached for
    /// this pid — reaching it independently here (this is the safety-net path, not the normal
    /// one) means the watcher's registration for it must be retired the same way: unregistered
    /// so a delayed/duplicate NOTE_EXIT for this pid can never land on whatever *new* run this
    /// program is on by the time it arrives, and reaped via `waitpid` so an own child doesn't
    /// linger as a zombie once nothing is left watching for its exit.
    private func reapDeadPid(_ pid: Int32) {
        exitWatcher.unregister(pid: pid)
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
    }

    /// design.md §3.8: a 3s delay before the post-wake double-check, so volumes/network have
    /// a moment to actually come back before `verifyAlive`'s `proc_pidinfo` call runs against
    /// a system that only just resumed.
    public func reconcileAfterWake() {
        queue.asyncAfter(deadline: .now() + 3) { [self] in
            reconcileLiveness()
            try? store.insertEvent(EventRecord(level: .info, type: .wakeReconcile))
        }
    }

    /// Cheap enough (one `proc_pidinfo` per active process) to also run whenever the status
    /// panel opens, per design.md's own recommendation for this kind of safety net.
    public func reconcileNow() {
        queue.async { [self] in reconcileLiveness() }
    }

    private func scheduleLivenessReconcile() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.reconcileLiveness() }
        timer.resume()
        livenessTimer = timer
    }

    // MARK: - Log rotation (design.md §4, ex-F10)

    /// `.onRestart` rotation happens inline in `spawnService`; this covers `.size`, which
    /// otherwise has no trigger at all — a service's log fd stays open via O_APPEND for its
    /// entire (possibly months-long) lifetime, so nothing short of a periodic `stat` can ever
    /// notice it crossed the configured limit.
    private func scheduleLogRotationCheck() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.checkLogRotationForActiveServices() }
        timer.resume()
        logRotationTimer = timer
    }

    private struct RotationCandidate {
        let programId: Int64
        let out: String
        let err: String
        let maxBytes: Int64
        let backups: Int
    }

    /// The paths/limits to check are read here, on the core queue, since they come out of
    /// `programs`/`serviceRuntimes` — but the actual rotation (`copyItem` of a log file that
    /// can legitimately be `logMaxBytes` large) runs off it. It used to run inline on this
    /// same serial queue that every process-exit event, start/stop command, and UI snapshot
    /// publish also goes through, so a slow copy for one flapping service's oversized log
    /// blocked supervision of every *other* managed process behind it — exactly the
    /// fault-isolation constraint design.md §1 rules out (ex-F43).
    private func checkLogRotationForActiveServices() {
        var candidates: [RotationCandidate] = []
        for (id, runtime) in serviceRuntimes where runtime.state.isActive {
            guard let program = programs[id], program.logRotatePolicy == .size else { continue }
            let paths = LogManager.serviceLogPaths(
                name: program.name, logsDir: logsDir, mergeStderr: program.logMergeStderr,
                explicitOutPath: program.logPath, explicitErrPath: program.logStderrPath
            )
            candidates.append(RotationCandidate(programId: id, out: paths.out, err: paths.err, maxBytes: program.logMaxBytes, backups: program.logBackups))
        }
        guard !candidates.isEmpty else { return }
        let candidatesToRotate = candidates
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for candidate in candidatesToRotate {
                var rotated = false
                var failure: Error?
                do {
                    rotated = try LogManager.rotateIfNeeded(path: candidate.out, maxBytes: candidate.maxBytes, backups: candidate.backups)
                } catch {
                    failure = error
                }
                if candidate.err != candidate.out {
                    do {
                        rotated = try LogManager.rotateIfNeeded(path: candidate.err, maxBytes: candidate.maxBytes, backups: candidate.backups) || rotated
                    } catch {
                        failure = failure ?? error
                    }
                }
                guard rotated || failure != nil else { continue }
                let didRotate = rotated
                let rotationFailure = failure
                guard let self else { return }
                self.queue.async {
                    if didRotate {
                        try? self.store.insertEvent(EventRecord(level: .info, programId: candidate.programId, type: .logRotated))
                    }
                    if let rotationFailure {
                        // design.md §4 promises "写失败不停止业务进程" for a full ENOSPC — the
                        // child's own writes go straight to its fd with Barback never in that
                        // path, so this periodic rotation check (which does touch the file) is
                        // the earliest point anything here can actually notice the disk is out
                        // of room, rather than staying silent the way a bare `try?` did before
                        // (ex-F43, `logWriteFailed` previously defined but never used).
                        let json = (try? JSONSerialization.data(withJSONObject: ["error": self.describe(rotationFailure)])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        try? self.store.insertEvent(EventRecord(level: .error, programId: candidate.programId, type: .logWriteFailed, detailJSON: json))
                    }
                }
            }
        }
    }

    // MARK: - Termination (design.md §3.6)

    public func stopAllForTermination(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            pendingTerminationHandlers.append(completion)
            // The app is quitting — no pending restart should survive to spawn a new
            // instance while everything else is being torn down (design.md §3.5, R08).
            pendingRestartAfterStop.removeAll()
            var anyActive = false
            for program in programs.values.filter({ $0.kind == .service }).sorted(by: Program.priorityDescending) {
                if serviceRuntimes[program.id]?.state.isActive == true {
                    anyActive = true
                    dispatchServiceEvent(programId: program.id, event: .stop)
                }
            }
            for program in programs.values.filter({ $0.kind == .oneshot }) {
                if oneshotRuntimes[program.id]?.state.isActive == true {
                    anyActive = true
                    dispatchOneshotEvent(programId: program.id, event: .cancel)
                }
            }
            try? store.insertEvent(EventRecord(level: .info, type: .appStopping))
            if !anyActive {
                runPendingTerminationIfIdle()
            } else {
                // Nothing before this bounded how long "正在停止所有被管进程…" could last: a
                // program stuck mid-spawn, or landed on a transition the state machine's
                // `default: break` doesn't cover, left `anyActive` true forever and the only
                // way out was a force-quit — which is exactly the scenario crash recovery
                // exists to clean up after (design.md §3.6, ex-F26).
                let maxWait = programs.values.map { Double($0.stopWaitSeconds) }.max() ?? 10
                scheduleTerminationTimeout(seconds: maxWait + 5)
            }
        }
    }

    private func scheduleTerminationTimeout(seconds: Double) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.forceKillEverythingForTermination()
            self.runPendingTerminationIfIdle()
        }
        timer.resume()
        terminationTimeoutTimer = timer
    }

    private func forceKillEverythingForTermination() {
        for (id, runtime) in serviceRuntimes where runtime.state.isActive {
            if let pid = runtime.pid {
                ProcessHost.sendKill(pid: pid, pgid: runtime.pgid, asGroup: true)
                exitWatcher.unregister(pid: pid) // ex-F45 — see finishDelete
            }
            var r = runtime
            r.state = .stopped
            r.pid = nil
            r.pgid = nil
            serviceRuntimes[id] = r
            // `persistLive` below is about to clear this program's `live` row entirely (state
            // is no longer active), so this is the last chance to close out its run row —
            // without it, the row stays `ended_at IS NULL` with no `live` row left pointing at
            // it either, an orphan that crash-recovery's live-table sweep can never find on the
            // next launch (R14).
            if let runId = currentRunId[id] {
                finalizeRun(programId: id, runId: runId, outcome: .cancelled, code: nil, signal: nil)
            }
            persistLive(programId: id)
        }
        for (id, runtime) in oneshotRuntimes where runtime.state.isActive {
            if let pid = runtime.pid {
                ProcessHost.sendKill(pid: pid, pgid: runtime.pgid, asGroup: true)
                exitWatcher.unregister(pid: pid)
            }
            var r = runtime
            r.state = .cancelled
            r.pid = nil
            r.pgid = nil
            oneshotRuntimes[id] = r
            if let runId = currentRunId[id] {
                finalizeRun(programId: id, runId: runId, outcome: .cancelled, code: nil, signal: nil)
            }
            persistLive(programId: id)
        }
    }

    private func runPendingTerminationIfIdle() {
        guard !pendingTerminationHandlers.isEmpty else { return }
        let anyActive = serviceRuntimes.values.contains { $0.state.isActive } || oneshotRuntimes.values.contains { $0.state.isActive }
        guard !anyActive else { return }
        terminationTimeoutTimer?.cancel()
        terminationTimeoutTimer = nil
        let handlers = pendingTerminationHandlers
        pendingTerminationHandlers.removeAll()
        for h in handlers { DispatchQueue.main.async { MainActor.assumeIsolated { h() } } }
    }

    public func hasActiveOneshots(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { completion(self.oneshotRuntimes.values.contains { $0.state.isActive }) }
    }

    // MARK: - Events / Runs read access for windows

    public func fetchEvents(limit: Int, programId: Int64?, level: EventLevel?, completion: @escaping @Sendable ([EventRecord]) -> Void) {
        queue.async { completion((try? self.store.fetchEvents(limit: limit, programId: programId, level: level)) ?? []) }
    }

    public func fetchRuns(programId: Int64?, limit: Int, completion: @escaping @Sendable ([RunRecord]) -> Void) {
        queue.async {
            if let programId {
                completion((try? self.store.fetchRuns(programId: programId, limit: limit)) ?? [])
            } else {
                completion((try? self.store.fetchAllRuns(limit: limit)) ?? [])
            }
        }
    }

    /// Deletes completed runs (and their output files) matching the history window's current
    /// filter. Runs still in flight are never touched by `Store.deleteRuns`, so this can't
    /// clip a program mid-execution no matter what filter is showing (design.md §6.6, ex-F02).
    public func clearHistory(programId: Int64?, outcome: RunOutcome?, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if let paths = try? store.deleteRuns(programId: programId, outcome: outcome) {
                removeRunOutputFiles(paths)
            }
            // The rows the cache mirrors may be exactly the ones just deleted.
            if let programId {
                refreshLastRun(programId: programId)
            } else {
                loadLastRuns()
            }
            publishSnapshot()
            completion()
        }
    }

    private func logSelf(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = (logsDir as NSString).appendingPathComponent("barback.log")
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }
}
