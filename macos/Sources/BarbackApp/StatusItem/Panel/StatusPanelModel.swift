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
    /// The panel's clock, advanced once a second by `startClock` while anything is running
    /// and frozen the rest of the time. Uptimes and the backoff countdown read from it rather
    /// than calling `Date()` during layout, so every row in one frame agrees on "now".
    @Published private(set) var now = Date()
    @Published private(set) var samples: [Int32: ProcSample] = [:]
    @Published var searchText = ""
    @Published var expandedId: Int64?
    /// Keyboard cursor. `nil` until someone presses ↑/↓ — the panel is a pointer-first
    /// surface and a selection ring on open would just be noise (BAR-10).
    @Published var selectedId: Int64?
    /// Transient confirmation line in the footer ("已复制 PID"), instead of a modal.
    @Published private(set) var toast: String?

    let appState: AppState
    weak var windowController: WindowController?
    var onRequestClose: (() -> Void)?

    private var toastTask: Task<Void, Never>?
    private var cpuSampleTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    /// Wall-clock window the CPU figure is measured over. Long enough that a short burst
    /// isn't rounded away, short enough that the number is there before anyone has finished
    /// reading the row.
    private static let cpuWindowNanoseconds: UInt64 = 800_000_000
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

    // MARK: - Sampling

    /// Samples CPU/RSS for whatever is showing right now, and starts the panel's clock.
    ///
    /// Sampling is driven by the panel opening rather than by a repeating timer — nobody
    /// needs second-by-second precision on these figures, and skipping the timer means zero
    /// sampling while the panel just sits open.
    ///
    /// It has to be *two* samples, not one: CPU% is a difference in consumed CPU time over
    /// a wall-clock window, so a single sample per open has nothing to subtract and could
    /// only ever render 0.0% — which is what the panel did for every program regardless of
    /// load. The follow-up sample supplies the other end of the window and then stops; the
    /// row shows "CPU —" in between.
    func startTicking() {
        tick()
        cpuSampleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.cpuWindowNanoseconds)
            guard !Task.isCancelled else { return }
            self?.tick()
        }
        startClock()
    }

    /// Advances `now` once a second while the panel is on screen.
    ///
    /// `backoffRemaining` is frozen at the moment the snapshot was published, and BACKOFF
    /// publishes nothing while it waits — so without a clock of its own the panel showed a
    /// countdown and a progress hairline that both sat perfectly still for as long as anyone
    /// looked at them, which design.md §6.3 explicitly says they shouldn't ("面板按本地时钟
    /// 推进，不必等定时器到点才更新"). This is a `Date()` assignment, not a resample: CPU/RSS
    /// still cost exactly the two samples per open they always did, and the tick is skipped
    /// entirely when nothing is running, so an all-stopped panel is as free as before.
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.needsClock else { continue }
                self.now = Date()
            }
        }
    }

    private var needsClock: Bool {
        appState.snapshot.programs.contains(where: \.isActive)
    }

    func stopTicking() {
        cpuSampleTask?.cancel()
        cpuSampleTask = nil
        clockTask?.cancel()
        clockTask = nil
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

    /// Runs whatever `StatusStyle.primaryAction` says the row's main button does. The row's
    /// button and ⌘↩ both come through here, so the label someone reads and the thing that
    /// happens can never drift apart.
    func performPrimary(_ snap: ProgramSnapshot) {
        switch StatusStyle.primaryAction(for: snap).kind {
        case .enable: enable(snap)
        case .start: start(snap)
        case .stop: stop(snap)
        case .forceKill: forceKill(snap)
        case .run: runOneshot(snap)
        case .cancel: cancelOneshot(snap)
        }
    }

    func start(_ snap: ProgramSnapshot) { appState.supervisor.start(id: snap.id) }
    func stop(_ snap: ProgramSnapshot) { appState.supervisor.stop(id: snap.id) }
    func restart(_ snap: ProgramSnapshot) { appState.supervisor.restart(id: snap.id) }
    func clearFatal(_ snap: ProgramSnapshot) { appState.supervisor.clearFatal(id: snap.id) }
    func cancelOneshot(_ snap: ProgramSnapshot) { appState.supervisor.cancelOneshot(id: snap.id) }

    /// Only reachable for a disabled, inactive service (see `ProgramRowView.primaryButton`) —
    /// flips `enabled` back on without also starting it, matching what "启用" promises as
    /// distinct from "启动" (design.md §6.3, ex-F06).
    func enable(_ snap: ProgramSnapshot) {
        var program = snap.program
        program.enabled = true
        appState.supervisor.validateAndSave(program) { _ in }
    }

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

    /// "全部停止" reads as "stop my services" — it silently took down any in-flight one-shot
    /// too, which is exactly the risk the quit flow already asks about before doing the same
    /// thing (`AppDelegate.applicationShouldTerminate`). This brings the panel action in line
    /// with that precedent (design.md §6.3, ex-F04).
    func stopAll() {
        appState.supervisor.hasActiveOneshots { [weak self] hasActive in
            DispatchQueue.main.async {
                guard let self else { return }
                guard hasActive else {
                    self.appState.supervisor.stopAll()
                    return
                }
                self.close()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "有一次性命令正在执行"
                alert.informativeText = "全部停止将同时终止它们。"
                alert.addButton(withTitle: "全部停止")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.appState.supervisor.stopAll()
            }
        }
    }

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

    // MARK: - Keyboard (BAR-10)

    /// The rows in the order the panel draws them — services by group, then one-shots — so
    /// ↑/↓ walks the list the eye sees rather than the order the dictionary happened to give.
    var navigableIds: [Int64] {
        serviceGroups.flatMap { $0.items.map(\.id) } + visiblePrograms(kind: .oneshot).map(\.id)
    }

    /// Handles a key the panel claims, and reports whether it did. Returning `false` lets the
    /// event fall through to the search field, which is otherwise the only thing here that
    /// wants the keyboard.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:
            moveSelection(-1)
            return true
        case NSDownArrowFunctionKey:
            moveSelection(1)
            return true
        case NSCarriageReturnCharacter, NSEnterCharacter:
            guard let snap = selectedProgram else { return false }
            // ↩ opens the drawer (the same thing clicking the row does) and ⌘↩ runs the
            // primary action. Deliberately that way round: ↩ right after typing in the search
            // field is far too easy to hit for it to stop a service.
            if event.modifierFlags.contains(.command) {
                performPrimary(snap)
            } else {
                toggleExpanded(snap.id)
            }
            return true
        case 0x1B: // esc
            close()
            return true
        default:
            return false
        }
    }

    var selectedProgram: ProgramSnapshot? {
        guard let selectedId else { return nil }
        return appState.program(id: selectedId)
    }

    private func moveSelection(_ delta: Int) {
        let ids = navigableIds
        guard !ids.isEmpty else { return }
        guard let selectedId, let index = ids.firstIndex(of: selectedId) else {
            selectedId = delta > 0 ? ids.first : ids.last
            return
        }
        let next = index + delta
        guard ids.indices.contains(next) else { return }
        self.selectedId = ids[next]
    }

    // MARK: - Grouping

    struct ServiceGroup {
        let title: String
        let items: [ProgramSnapshot]
    }

    /// Services are only broken out by group once more than one group is actually in use —
    /// otherwise the headers are pure noise. Lives here rather than in the view because
    /// keyboard traversal has to walk the same order the view draws.
    var serviceGroups: [ServiceGroup] {
        let services = visiblePrograms(kind: .service)
        var order: [String] = []
        var buckets: [String: [ProgramSnapshot]] = [:]
        for snap in services {
            let key = snap.program.groupName?.isEmpty == false ? snap.program.groupName! : "未分组"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(snap)
        }
        guard order.count > 1 else { return [ServiceGroup(title: "服务", items: services)] }
        return order.map { ServiceGroup(title: $0, items: buckets[$0] ?? []) }
    }

    // MARK: - Windows

    func dismissRecoveryNotice() {
        appState.supervisor.dismissRecoveryNotice()
    }

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
