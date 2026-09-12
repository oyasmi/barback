import AppKit
import Combine
import SwiftUI
import BarbackCore

/// View state for the left-click panel, and the single place the panel's actions are
/// spelled out. Created when the panel opens and torn down when it closes, so the
/// once-a-second sampling it drives exists only while someone is looking (design.md §6.2
/// 常态零开销).
@MainActor
final class StatusPanelModel: ObservableObject {
    /// Advances every second while the panel is open; uptimes and countdowns read from it.
    @Published private(set) var now = Date()
    @Published private(set) var samples: [Int32: ProcSample] = [:]
    @Published var searchText = ""
    @Published var expandedId: Int64?
    /// Transient confirmation line in the footer ("已复制 PID"), instead of a modal.
    @Published private(set) var toast: String?

    let appState: AppState
    weak var windowController: WindowController?
    var onRequestClose: (() -> Void)?

    private var ticker: Timer?
    private var toastTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// When the snapshot we are showing was produced. `backoffRemaining` is frozen at
    /// publish time, so the countdown has to be advanced against this anchor rather than
    /// waiting for a snapshot that only arrives when the timer finally fires.
    private var snapshotReceivedAt = Date()
    /// Longest remaining time seen for the current backoff window, so the hairline has
    /// something to be a fraction of.
    private var backoffSpan: [Int64: TimeInterval] = [:]

    init(appState: AppState, windowController: WindowController?) {
        self.appState = appState
        self.windowController = windowController
        appState.$snapshot
            .sink { [weak self] _ in self?.snapshotReceivedAt = Date() }
            .store(in: &cancellables)
    }

    // MARK: - Live sampling

    func startTicking() {
        guard ticker == nil else { return }
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.2
        ticker = timer
    }

    func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        toastTask?.cancel()
        for pid in samples.keys { ProcSampler.clearHistory(pid: pid) }
        samples.removeAll()
    }

    private func tick() {
        now = Date()
        var fresh: [Int32: ProcSample] = [:]
        for snap in appState.snapshot.programs {
            guard let pid = snap.pid else { continue }
            if let sample = ProcSampler.sample(pid: pid) { fresh[pid] = sample }
        }
        for pid in samples.keys where fresh[pid] == nil {
            ProcSampler.clearHistory(pid: pid)
        }
        samples = fresh
    }

    func sample(for snap: ProgramSnapshot) -> ProcSample? {
        snap.pid.flatMap { samples[$0] }
    }

    /// Backoff seconds left, advanced past the snapshot we were handed.
    func backoffRemaining(for snap: ProgramSnapshot) -> TimeInterval? {
        guard let published = snap.backoffRemaining else { return nil }
        return max(0, published - now.timeIntervalSince(snapshotReceivedAt))
    }

    /// How far through the current backoff wait we are, 0…1.
    func backoffProgress(for snap: ProgramSnapshot) -> Double {
        guard let remaining = backoffRemaining(for: snap) else { return 0 }
        let span = max(backoffSpan[snap.id] ?? 0, remaining)
        backoffSpan[snap.id] = span
        guard span > 0 else { return 0 }
        return 1 - (remaining / span)
    }

    // MARK: - Filtering

    var isSearchable: Bool { appState.snapshot.programs.count > 8 }

    func visiblePrograms(kind: ProgramKind) -> [ProgramSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return appState.snapshot.programs.filter { snap in
            guard snap.program.kind == kind else { return false }
            guard !query.isEmpty else { return true }
            return snap.program.name.localizedCaseInsensitiveContains(query)
                || snap.program.command.localizedCaseInsensitiveContains(query)
                || (snap.program.groupName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    // MARK: - Per-program actions

    func toggleExpanded(_ id: Int64) {
        expandedId = expandedId == id ? nil : id
    }

    func start(_ snap: ProgramSnapshot) { appState.supervisor.start(id: snap.id) }
    func stop(_ snap: ProgramSnapshot) { appState.supervisor.stop(id: snap.id) }
    func restart(_ snap: ProgramSnapshot) { appState.supervisor.restart(id: snap.id) }
    func clearFatal(_ snap: ProgramSnapshot) { appState.supervisor.clearFatal(id: snap.id) }
    func cancelOneshot(_ snap: ProgramSnapshot) { appState.supervisor.cancelOneshot(id: snap.id) }

    func runOneshot(_ snap: ProgramSnapshot) {
        guard snap.program.confirmBeforeRun else {
            appState.supervisor.runOneshot(id: snap.id)
            return
        }
        // The confirmation is a modal alert, which would pull focus out from under a
        // transient popover; close first so the panel doesn't vanish mid-question.
        close()
        windowController?.confirmRun(programId: snap.id)
    }

    /// SIGKILL has no cleanup path for the child, so it asks first.
    func forceKill(_ snap: ProgramSnapshot) {
        close()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "强制终止「\(snap.program.name)」？"
        alert.informativeText = "将直接发送 SIGKILL，进程没有机会保存状态或清理资源。"
        alert.addButton(withTitle: "强制终止")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        appState.supervisor.forceKill(id: snap.id)
    }

    // MARK: - Global actions

    func startAll() { appState.supervisor.startAll() }
    func stopAll() { appState.supervisor.stopAll() }
    func restartAll() { appState.supervisor.restartAll() }

    var canStartAll: Bool {
        appState.snapshot.programs.contains {
            $0.program.kind == .service && $0.program.enabled && !($0.serviceState?.isActive ?? false)
        }
    }

    var canStopAll: Bool {
        appState.snapshot.programs.contains(where: \.isActive)
    }

    var hasServices: Bool {
        appState.snapshot.programs.contains { $0.program.kind == .service }
    }

    // MARK: - Windows

    func openConfig(selecting id: Int64? = nil) {
        close()
        windowController?.showConfigWindow(selecting: id)
    }

    func openLog(_ snap: ProgramSnapshot) {
        close()
        windowController?.showLogWindow(programId: snap.id)
    }

    func revealLog(_ snap: ProgramSnapshot) {
        close()
        windowController?.revealLog(programId: snap.id)
    }

    func openHistory(_ snap: ProgramSnapshot) {
        close()
        windowController?.showHistoryWindow(programId: snap.id)
    }

    // MARK: - Clipboard

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("已复制\(label)")
    }

    private func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func close() {
        onRequestClose?()
    }
}
