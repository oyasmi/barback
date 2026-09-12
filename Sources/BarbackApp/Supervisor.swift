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
    private var pendingTerminationHandlers: [() -> Void] = []
    private var recoveredCount = 0

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
            for program in programs.values.filter({ $0.kind == .service }) {
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
                        markNeedsRestart(saved.id)
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

    public func deleteProgram(id: Int64, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if serviceRuntimes[id]?.state.isActive == true {
                dispatchServiceEvent(programId: id, event: .stop)
            }
            try? store.deleteProgram(id: id)
            programs.removeValue(forKey: id)
            serviceRuntimes.removeValue(forKey: id)
            oneshotRuntimes.removeValue(forKey: id)
            publishSnapshot()
            completion()
        }
    }

    private func isRunning(_ id: Int64) -> Bool {
        serviceRuntimes[id]?.state.isActive == true || oneshotRuntimes[id]?.state.isActive == true
    }

    private func markNeedsRestart(_ id: Int64) {
        var live = LiveRecord(programId: id, appBootId: appBootId, state: serviceRuntimes[id]?.state.rawValue ?? "STOPPED")
        live.needsRestart = true
        try? store.upsertLive(live)
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
            scheduleTimer(&startTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchServiceEvent(programId: programId, event: .startSecondsElapsed)
            }
        case .cancelStartTimer:
            cancelTimer(&startTimers, id: programId)
        case .scheduleBackoffTimer(let seconds):
            backoffEndDates[programId] = Date().addingTimeInterval(seconds)
            scheduleTimer(&backoffTimers, id: programId, seconds: seconds) { [weak self] in
                self?.backoffEndDates.removeValue(forKey: programId)
                self?.dispatchServiceEvent(programId: programId, event: .backoffElapsed)
            }
        case .cancelBackoffTimer:
            cancelTimer(&backoffTimers, id: programId)
            backoffEndDates.removeValue(forKey: programId)
        case .sendSignal(let name, let group):
            if let runtime = serviceRuntimes[programId], let pid = runtime.pid {
                ProcessHost.signal(pid: pid, pgid: runtime.pgid, name: name, asGroup: group)
            }
        case .scheduleStopTimer(let seconds):
            scheduleTimer(&stopTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchServiceEvent(programId: programId, event: .stopTimerElapsed)
            }
        case .cancelStopTimer:
            cancelTimer(&stopTimers, id: programId)
        case .sendKill(let group):
            if let runtime = serviceRuntimes[programId], let pid = runtime.pid {
                ProcessHost.sendKill(pid: pid, pgid: runtime.pgid, asGroup: group)
            }
        case .scheduleStopGrace(let seconds):
            scheduleTimer(&stopGraceTimers, id: programId, seconds: seconds) { [weak self] in
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
                }
            }
        case .persistLive:
            persistLive(programId: programId)
        case .publishSnapshot:
            publishSnapshot()
            checkRestartAfterStop(programId: programId)
            runPendingTerminationIfIdle()
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
        }
    }

    private func checkRestartAfterStop(programId: Int64) {
        guard pendingRestartAfterStop.contains(programId) else { return }
        guard let runtime = serviceRuntimes[programId], runtime.state == .stopped else { return }
        pendingRestartAfterStop.remove(programId)
        dispatchServiceEvent(programId: programId, event: .start(trigger: .manual))
    }

    private func spawnService(program: Program, trigger: RunTrigger) {
        do {
            let logFDs = try LogManager.openServiceLogs(
                name: program.name,
                logsDir: AppPaths.logsDir,
                mergeStderr: program.logMergeStderr,
                explicitOutPath: program.logPath,
                explicitErrPath: program.logStderrPath
            )
            let runId = try store.insertRun(RunRecord(programId: program.id, trigger: trigger, logPath: logFDs.outPath))
            currentRunId[program.id] = runId
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
        if case .run = event, runtime.state == .running, !program.allowConcurrent { return }
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
            scheduleTimer(&stopTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchOneshotEvent(programId: programId, event: .stopTimerElapsed)
            }
        case .cancelStopTimer:
            cancelTimer(&stopTimers, id: programId)
        case .scheduleTimeoutTimer(let seconds):
            scheduleTimer(&timeoutTimers, id: programId, seconds: seconds) { [weak self] in
                self?.dispatchOneshotEvent(programId: programId, event: .timeoutElapsed)
            }
        case .cancelTimeoutTimer:
            cancelTimer(&timeoutTimers, id: programId)
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
        do {
            let runId = try store.insertRun(RunRecord(programId: program.id, trigger: .manual))
            let logFDs = try LogManager.openRunLog(name: program.name, runId: runId, logsDir: AppPaths.logsDir)
            currentRunId[program.id] = runId
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

    private func scheduleTimer(_ storage: inout [Int64: DispatchSourceTimer], id: Int64, seconds: Double, handler: @escaping () -> Void) {
        storage[id]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let leeway = max(seconds * 0.1, 1.0)
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(Int(leeway * 1000)))
        timer.setEventHandler { [weak self] in
            self?.clearTimer(id: id)
            handler()
        }
        storage[id] = timer
        timer.resume()
    }

    private func clearTimer(id: Int64) {
        // Timers self-remove from whichever storage dict fired; safe no-op otherwise.
    }

    private func cancelTimer(_ storage: inout [Int64: DispatchSourceTimer], id: Int64) {
        storage[id]?.cancel()
        storage.removeValue(forKey: id)
    }

    // MARK: - Snapshot publishing

    private func publishSnapshot() {
        let snapshotPrograms: [ProgramSnapshot] = programs.values.map { program in
            let lastRun = (try? store.fetchRuns(programId: program.id, limit: 1))?.first
            let runCount = (try? store.fetchRuns(programId: program.id, limit: 100000))?.count ?? 0
            if program.kind == .service {
                let runtime = serviceRuntimes[program.id] ?? ServiceRuntime()
                let remaining = backoffEndDates[program.id].map { max(0, $0.timeIntervalSinceNow) }
                return ProgramSnapshot(
                    program: program, serviceState: runtime.state, oneshotState: nil,
                    pid: runtime.pid, startedAt: runtime.startedAt, retryCount: runtime.retryCount,
                    backoffRemaining: remaining, lastRun: lastRun, runCount: runCount, needsRestart: false
                )
            } else {
                let runtime = oneshotRuntimes[program.id] ?? OneshotRuntime()
                return ProgramSnapshot(
                    program: program, serviceState: nil, oneshotState: runtime.state,
                    pid: runtime.pid, startedAt: nil, retryCount: 0,
                    backoffRemaining: nil, lastRun: lastRun, runCount: runCount, needsRestart: false
                )
            }
        }.sorted { $0.program.priority < $1.program.priority }
        let snapshot = SupervisorSnapshot(programs: snapshotPrograms, recoveredCount: recoveredCount)
        let callback = onSnapshot
        DispatchQueue.main.async { callback?(snapshot) }
    }

    // MARK: - Sleep/wake reconciliation (design.md §3.8)

    public func reconcileAfterWake() {
        queue.async { [self] in
            for (id, runtime) in serviceRuntimes where runtime.state.isActive {
                guard let pid = runtime.pid, let startTime = runtime.procStartTime else { continue }
                if !ProcessHost.verifyAlive(pid: pid, expectedStartTime: startTime) {
                    dispatchServiceEvent(programId: id, event: .processExited(code: nil, signal: nil, at: Date()))
                }
            }
            try? store.insertEvent(EventRecord(level: .info, type: .wakeReconcile))
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
            }
        }
    }

    private func runPendingTerminationIfIdle() {
        guard !pendingTerminationHandlers.isEmpty else { return }
        let anyActive = serviceRuntimes.values.contains { $0.state.isActive } || oneshotRuntimes.values.contains { $0.state.isActive }
        guard !anyActive else { return }
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
