import Foundation
import BarbackCore
import UserNotifications

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
    private var pendingTerminationHandlers: [() -> Void] = []
    private var terminationTimeoutTimer: DispatchSourceTimer?
    private var recoveredCount = 0
    /// Programs mid-delete: the row stays in `programs` (so in-flight events still resolve
    /// normally) until the stop it kicked off actually finishes, then `checkPendingDeletion`
    /// runs the completion (design.md §3.7 — deleting a running program must not orphan it).
    private var pendingDeletions: [Int64: () -> Void] = [:]
    private var logRotationTimer: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?

    public var onSnapshot: (@Sendable (SupervisorSnapshot) -> Void)?
    public var onNotify: (@Sendable (NotificationKind) -> Void)?
    public var onOneshotNotify: (@Sendable (Program, OneshotState, TimeInterval) -> Void)?

    public init(store: Store) {
        self.store = store
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
            recoverFromCrashIfNeeded()
            try? store.insertEvent(EventRecord(level: .info, type: .appStarted))
            autostartServices()
            publishSnapshot()
            scheduleLogRotationCheck()
            scheduleLivenessReconcile()
        }
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
        isOwnChild[program.id] = false
        exitWatcher.register(pid: pid, isOwnChild: false) { [weak self] status in
            self?.handleProcessExited(programId: program.id, status: status)
        }
        switch program.kind {
        case .service:
            var runtime = ServiceRuntime(state: .running, pid: live.pid, pgid: live.pgid, procStartTime: live.procStartTime, startedAt: live.startedAt.map(Date.init(timeIntervalSince1970:)))
            runtime.retryCount = live.retryCount
            serviceRuntimes[program.id] = runtime
        case .oneshot:
            oneshotRuntimes[program.id] = OneshotRuntime(state: .running, pid: live.pid, pgid: live.pgid, procStartTime: live.procStartTime)
        }
        persistLive(programId: program.id)
    }

    private func handleUnknownOutcome(program: Program, live: LiveRecord) {
        try? store.clearLive(programId: program.id)
        switch program.kind {
        case .service:
            serviceRuntimes[program.id] = ServiceRuntime(state: .stopped)
            // autorestart semantics decide whether autostart below relaunches it.
        case .oneshot:
            oneshotRuntimes[program.id] = OneshotRuntime(state: .failed)
        }
    }

    private func autostartServices() {
        let services = programs.values
            .filter { $0.kind == .service && $0.enabled && $0.autostart }
            .sorted { $0.priority < $1.priority }
        for program in services {
            let runtime = serviceRuntimes[program.id] ?? ServiceRuntime()
            guard runtime.state == .stopped || runtime.state == .exited else { continue }
            dispatchServiceEvent(programId: program.id, event: .start(trigger: .autostart))
        }
    }

    // MARK: - Public commands (all hop to core queue)

    public func start(id: Int64) { queue.async { self.dispatchServiceEvent(programId: id, event: .start(trigger: .manual)) } }
    public func stop(id: Int64) { queue.async { self.dispatchServiceEvent(programId: id, event: .stop) } }
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
            for program in programs.values.filter({ $0.kind == .service && $0.enabled }).sorted(by: { $0.priority < $1.priority }) {
                dispatchServiceEvent(programId: program.id, event: .start(trigger: .manual))
            }
        }
    }
    public func stopAll(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            for program in programs.values.filter({ $0.kind == .service }).sorted(by: { $0.priority > $1.priority }) {
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
                .sorted(by: { $0.priority < $1.priority }) {
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
        queue.async { completion(Array(self.programs.values).sorted { $0.priority < $1.priority }) }
    }

    public func validateAndSave(_ program: Program, completion: @escaping @Sendable (Result<Program, ProgramSaveError>) -> Void) {
        queue.async { [self] in
            var existing = Set(programs.values.map(\.name))
            if program.id != 0 { existing.remove(programs[program.id]?.name ?? "") }
            let errors = ProgramValidator.validate(program, existingNames: existing)
            guard errors.isEmpty else {
                completion(.failure(.validation(errors)))
                return
            }
            do {
                var saved = program
                if saved.id == 0 {
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
                    try store.updateProgram(saved)
                    programs[saved.id] = saved
                    if let old, runtimeFieldsChanged(old, saved), isRunning(saved.id) {
                        needsRestartIds.insert(saved.id)
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
        try? store.deleteProgram(id: id)
        programs.removeValue(forKey: id)
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
        a.command != b.command || a.useShell != b.useShell || a.directory != b.directory ||
        a.environment != b.environment || a.logPath != b.logPath || a.logStderrPath != b.logStderrPath ||
        a.stopSignal != b.stopSignal || a.stopWaitSeconds != b.stopWaitSeconds || a.timeoutSeconds != b.timeoutSeconds
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
                while existing.contains(name) {
                    name = "\(draft.name)-\(suffix)"
                    suffix += 1
                }
                draft.name = name
                existing.insert(name)
                if let id = try? store.insertProgram(draft) {
                    draft.id = id
                    programs[id] = draft
                    serviceRuntimes[id] = ServiceRuntime()
                    saved.append(draft)
                }
            }
            try? store.insertEvent(EventRecord(level: .info, type: .imported, detailJSON: "{\"count\":\(saved.count)}"))
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
            if let pid {
                ProcessHost.sendKill(pid: pid, pgid: pgid, asGroup: group)
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
                    self.persistLive(programId: programId)
                    self.publishSnapshot()
                    self.runPendingTerminationIfIdle()
                    self.checkPendingDeletion(programId: programId)
                }
            }
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
                try? store.finalizeRun(id: runId, endedAt: Date(), exitCode: code, termSignal: signal, outcome: outcome)
                currentRunId.removeValue(forKey: programId)
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
        do {
            if program.logRotatePolicy == .onRestart {
                let paths = LogManager.serviceLogPaths(
                    name: program.name, logsDir: AppPaths.logsDir, mergeStderr: program.logMergeStderr,
                    explicitOutPath: program.logPath, explicitErrPath: program.logStderrPath
                )
                _ = try? LogManager.rotateIfNeeded(path: paths.out, maxBytes: program.logMaxBytes, backups: program.logBackups, force: true)
                if paths.err != paths.out {
                    _ = try? LogManager.rotateIfNeeded(path: paths.err, maxBytes: program.logMaxBytes, backups: program.logBackups, force: true)
                }
            }
            let logFDs = try LogManager.openServiceLogs(
                name: program.name,
                logsDir: AppPaths.logsDir,
                mergeStderr: program.logMergeStderr,
                explicitOutPath: program.logPath,
                explicitErrPath: program.logStderrPath
            )
            let runId = try store.insertRun(RunRecord(programId: program.id, trigger: trigger, logPath: logFDs.outPath))
            currentRunId[program.id] = runId
            if var p = programs[program.id] { p.runTotal += 1; programs[program.id] = p }
            let env = mergedEnvironment(for: program)
            let spawned = try ProcessHost.spawn(
                command: program.command,
                useShell: program.useShell,
                directory: program.directory,
                environment: env,
                outFD: logFDs.outFD,
                errFD: logFDs.errFD
            )
            LogManager.closeFDs(logFDs) // parent's copies are no longer needed once dup2'd into the child
            isOwnChild[program.id] = true
            exitWatcher.register(pid: spawned.pid, isOwnChild: true) { [weak self] status in
                self?.handleProcessExited(programId: program.id, status: status)
            }
            dispatchServiceEvent(programId: program.id, event: .spawnSucceeded(pid: spawned.pid, pgid: spawned.pgid, procStartTime: spawned.startTime, at: Date()))
        } catch {
            currentRunId.removeValue(forKey: program.id)
            logSelf("启动失败 \(program.name): \(error)")
            dispatchServiceEvent(programId: program.id, event: .spawnFailed)
        }
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
        case .notify(let outcome):
            if let runId = currentRunId[programId], let run = try? store.fetchRuns(programId: programId, limit: 1).first {
                onOneshotNotify?(program, outcome, run.duration ?? 0)
                _ = runId
            } else {
                onOneshotNotify?(program, outcome, 0)
            }
        case .finalizeRun(let outcome, let code, let signal):
            if let runId = currentRunId[programId] {
                try? store.finalizeRun(id: runId, endedAt: Date(), exitCode: code, termSignal: signal, outcome: outcome)
                currentRunId.removeValue(forKey: programId)
            }
        }
    }

    private func spawnOneshot(program: Program) {
        needsRestartIds.remove(program.id)
        do {
            let runId = try store.insertRun(RunRecord(programId: program.id, trigger: .manual))
            let logFDs = try LogManager.openRunLog(name: program.name, runId: runId, logsDir: AppPaths.logsDir)
            currentRunId[program.id] = runId
            if var p = programs[program.id] { p.runTotal += 1; programs[program.id] = p }
            let env = mergedEnvironment(for: program)
            let spawned = try ProcessHost.spawn(
                command: program.command,
                useShell: program.useShell,
                directory: program.directory,
                environment: env,
                outFD: logFDs.outFD,
                errFD: logFDs.errFD
            )
            LogManager.closeFDs(logFDs)
            isOwnChild[program.id] = true
            exitWatcher.register(pid: spawned.pid, isOwnChild: true) { [weak self] status in
                self?.handleProcessExited(programId: program.id, status: status)
            }
            dispatchOneshotEvent(programId: program.id, event: .spawnSucceeded(pid: spawned.pid, pgid: spawned.pgid, procStartTime: spawned.startTime, at: Date()))
        } catch {
            currentRunId.removeValue(forKey: program.id)
            dispatchOneshotEvent(programId: program.id, event: .spawnFailed)
        }
    }

    private func trimHistoryIfNeeded(program: Program) {
        guard let paths = try? store.trimRunHistory(programId: program.id, historyLimit: program.historyLimit) else { return }
        for path in paths {
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

    private func publishSnapshot() {
        let snapshotPrograms: [ProgramSnapshot] = programs.values.map { program in
            let lastRun = (try? store.fetchRuns(programId: program.id, limit: 1))?.first
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
        }.sorted { $0.program.priority < $1.program.priority }
        let snapshot = SupervisorSnapshot(programs: snapshotPrograms, recoveredCount: recoveredCount)
        let callback = onSnapshot
        DispatchQueue.main.async { callback?(snapshot) }
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
                dispatchServiceEvent(programId: id, event: .processExited(code: nil, signal: nil, at: Date()))
            }
        }
        for (id, runtime) in oneshotRuntimes where runtime.state.isActive {
            guard let pid = runtime.pid, let startTime = runtime.procStartTime else { continue }
            if !ProcessHost.verifyAlive(pid: pid, expectedStartTime: startTime) {
                dispatchOneshotEvent(programId: id, event: .processExited(code: nil, signal: nil, at: Date()))
            }
        }
    }

    public func reconcileAfterWake() {
        queue.async { [self] in
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

    private func checkLogRotationForActiveServices() {
        for (id, runtime) in serviceRuntimes where runtime.state.isActive {
            guard let program = programs[id], program.logRotatePolicy == .size else { continue }
            let paths = LogManager.serviceLogPaths(
                name: program.name, logsDir: AppPaths.logsDir, mergeStderr: program.logMergeStderr,
                explicitOutPath: program.logPath, explicitErrPath: program.logStderrPath
            )
            _ = try? LogManager.rotateIfNeeded(path: paths.out, maxBytes: program.logMaxBytes, backups: program.logBackups)
            if paths.err != paths.out {
                _ = try? LogManager.rotateIfNeeded(path: paths.err, maxBytes: program.logMaxBytes, backups: program.logBackups)
            }
        }
    }

    // MARK: - Termination (design.md §3.6)

    public func stopAllForTermination(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            pendingTerminationHandlers.append(completion)
            var anyActive = false
            for program in programs.values.filter({ $0.kind == .service }).sorted(by: { $0.priority > $1.priority }) {
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
            if let pid = runtime.pid { ProcessHost.sendKill(pid: pid, pgid: runtime.pgid, asGroup: true) }
            var r = runtime
            r.state = .stopped
            r.pid = nil
            r.pgid = nil
            serviceRuntimes[id] = r
            persistLive(programId: id)
        }
        for (id, runtime) in oneshotRuntimes where runtime.state.isActive {
            if let pid = runtime.pid { ProcessHost.sendKill(pid: pid, pgid: runtime.pgid, asGroup: true) }
            var r = runtime
            r.state = .cancelled
            r.pid = nil
            r.pgid = nil
            oneshotRuntimes[id] = r
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
        for h in handlers { DispatchQueue.main.async(execute: h) }
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
                for path in paths { try? FileManager.default.removeItem(atPath: path) }
            }
            completion()
        }
    }

    private func logSelf(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = AppPaths.selfLogPath
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
