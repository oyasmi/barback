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
    /// The header chip someone clicked, narrowing the list to that state. Cleared on its own
    /// once nothing matches any more — the chip it belongs to may have disappeared with its
    /// count, and a filter with no visible way to turn it off is a trap.
    @Published var filter: PanelFilter?
    /// Newest warn/error event from the last day, for the footer: the supervisor restarts a
    /// crashed service silently, and this is where someone finds out it happened at all.
    @Published private(set) var recentProblem: EventRecord?

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
    /// Between `startTicking` and `stopTicking`; the event query only runs while it is set.
    private var isOpen = false

    init(appState: AppState, windowController: WindowController?) {
        self.appState = appState
        self.windowController = windowController
        // `$snapshot` fires before the property is assigned, so read the value it hands over.
        appState.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.snapshotReceivedAt = Date()
                if let filter = self.filter, !snapshot.programs.contains(where: filter.matches) {
                    self.filter = nil
                }
                if self.isOpen { self.fetchRecentProblem() }
            }
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
        isOpen = true
        fetchRecentProblem()
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
        isOpen = false
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

    /// Footer line when nothing more pressing is showing: how many processes are live and
    /// what they cost together. CPU drops out until the second sample lands (see `cpu`).
    var resourceSummary: String? {
        let active = appState.snapshot.programs.filter(\.isActive)
        guard !active.isEmpty else { return nil }
        var parts = [String(localized: "\(active.count) 个进程运行中")]
        let sampled = active.compactMap { sample(for: $0) }
        let cpus = sampled.compactMap(\.cpuPercent)
        if !cpus.isEmpty { parts.append("CPU \(StatusStyle.cpu(cpus.reduce(0, +)))") }
        if !sampled.isEmpty { parts.append(StatusStyle.memory(sampled.reduce(0) { $0 + $1.rssBytes })) }
        return parts.joined(separator: " · ")
    }

    /// One indexed read of the newest events, on open and whenever the snapshot moves while
    /// open — no polling (design.md §1).
    private func fetchRecentProblem() {
        let cutoff = Date().addingTimeInterval(-86_400)
        appState.supervisor.fetchEvents(limit: 50, programId: nil, level: nil) { events in
            let problem = events.first { $0.level != .info && $0.ts >= cutoff }
            Task { @MainActor in
                guard self.isOpen else { return }
                self.recentProblem = problem
            }
        }
    }

    /// "nslocal 进程已退出 · 12 分钟前" — the program, what happened, how long ago.
    func describe(_ event: EventRecord) -> String {
        var head = event.type.displayText
        if let id = event.programId, let snap = appState.program(id: id) {
            head = snap.program.name + " " + head
        }
        return head + " · " + StatusStyle.relative(event.ts, now: now)
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

    /// Chip counts come from the same predicate the filter applies, so a chip can never
    /// promise rows the filter then doesn't show.
    func count(_ filter: PanelFilter) -> Int {
        appState.snapshot.programs.filter(filter.matches).count
    }

    func toggleFilter(_ filter: PanelFilter) {
        self.filter = self.filter == filter ? nil : filter
    }

    func visiblePrograms(kind: ProgramKind) -> [ProgramSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return appState.snapshot.programs.filter { snap in
            guard snap.program.kind == kind else { return false }
            if let filter, !filter.matches(snap) { return false }
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
        alert.messageText = String(localized: "强制终止「\(snap.program.name)」？")
        alert.informativeText = String(localized: "将直接发送 SIGKILL，进程没有机会保存状态或清理资源。")
        alert.addButton(withTitle: String(localized: "强制终止"))
        alert.addButton(withTitle: String(localized: "取消"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        appState.supervisor.forceKill(id: snap.id)
    }

    // MARK: - Global actions

    func startAll() { appState.supervisor.startAll() }

    /// The footer's one visible bulk button: 全部启动 while anything is left to start,
    /// otherwise 全部停止. The other two live in the chevron menu beside it — they are rare,
    /// and both already stop to confirm.
    var prefersStartAll: Bool { canStartAll || !canStopAll }

    /// String(localized: "全部停止") / String(localized: "全部重启") sit one click away in a transient popover, and a stray click
    /// used to take every service down without a word (only in-flight one-shots were asked
    /// about, ex-F04). Both now confirm first and name what they touch, matching the quit flow
    /// (`AppDelegate.applicationShouldTerminate`) and the Windows workbench (design.md §6.3).
    func stopAll() {
        let active = appState.snapshot.programs.filter(\.isActive)
        guard !active.isEmpty else { return }
        let oneshots = active.filter { $0.program.kind == .oneshot }.count
        let detail = oneshots > 0
            ? String(localized: "将停止 \(active.count) 个正在运行的程序，其中 \(oneshots) 个一次性命令会被终止。")
            : String(localized: "将停止 \(active.count) 个正在运行的服务。")
        guard confirmBulkAction(title: String(localized: "全部停止？"), detail: detail, names: active.map(\.program.name), button: String(localized: "全部停止")) else { return }
        appState.supervisor.stopAll()
    }

    func restartAll() {
        // Same selection as `Supervisor.restartAll`: services that are running right now.
        let running = appState.snapshot.programs.filter { $0.program.kind == .service && $0.isActive }
        guard !running.isEmpty else { return }
        guard confirmBulkAction(title: String(localized: "全部重启？"), detail: String(localized: "将依次重启 \(running.count) 个正在运行的服务。"),
                                names: running.map(\.program.name), button: String(localized: "全部重启")) else { return }
        appState.supervisor.restartAll()
    }

    /// The alert is modal and would pull focus out from under the popover, so the panel
    /// closes first (same as `forceKill`).
    private func confirmBulkAction(title: String, detail: String, names: [String], button: String) -> Bool {
        close()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let listed = names.sorted().prefix(12).joined(separator: "\n")
        alert.informativeText = detail + "\n\n" + listed + (names.count > 12 ? "\n…" : "")
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "取消"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    var canStartAll: Bool {
        appState.snapshot.programs.contains {
            $0.program.kind == .service && $0.program.enabled && !($0.serviceState?.isActive ?? false)
        }
    }

    var canStopAll: Bool {
        appState.snapshot.programs.contains(where: \.isActive)
    }

    var canRestartAll: Bool {
        appState.snapshot.programs.contains { $0.program.kind == .service && $0.isActive }
    }

    // MARK: - Keyboard (BAR-10)

    /// The rows in the order the panel draws them — 需要处理, services by group, then
    /// one-shots — so ↑/↓ walks the list the eye sees rather than the order the dictionary
    /// happened to give.
    var navigableIds: [Int64] {
        attentionPrograms.map(\.id)
            + serviceGroups.flatMap { $0.items.map(\.id) }
            + visiblePrograms(kind: .oneshot).map(\.id)
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
            // Peel back one layer at a time, the way a search field's Esc does everywhere else.
            if !searchText.isEmpty {
                searchText = ""
            } else if filter != nil {
                filter = nil
            } else {
                close()
            }
            return true
        default:
            break
        }
        // ⌘L / ⌘R reach the two secondary actions people use most without opening the drawer.
        guard event.modifierFlags.contains(.command), let snap = selectedProgram else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "l":
            openLog(snap)
            return true
        case "r":
            guard snap.program.kind == .service, snap.serviceState?.isActive == true else { return false }
            restart(snap)
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

    /// Failing or waiting services, lifted above everything else so a FATAL fifteen rows down
    /// is not below the fold (StatusStyle.needsAttention).
    var attentionPrograms: [ProgramSnapshot] {
        visiblePrograms(kind: .service).filter(StatusStyle.needsAttention)
    }

    /// Services are only broken out by group once more than one group is actually in use —
    /// otherwise the headers are pure noise. Lives here rather than in the view because
    /// keyboard traversal has to walk the same order the view draws. Rows shown under
    /// 需要处理 are left out, so nothing appears twice.
    var serviceGroups: [ServiceGroup] {
        let services = visiblePrograms(kind: .service).filter { !StatusStyle.needsAttention($0) }
        guard !services.isEmpty else { return [] }
        var order: [String] = []
        var buckets: [String: [ProgramSnapshot]] = [:]
        for snap in services {
            let key = snap.program.groupName?.isEmpty == false ? snap.program.groupName! : String(localized: "未分组")
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(snap)
        }
        guard order.count > 1 else { return [ServiceGroup(title: String(localized: "服务"), items: services)] }
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

    func openEvents() {
        close()
        windowController?.showEventsWindow()
    }

    /// Pops the right-click menu up from the panel's ⋯ button. Each action opens a window or
    /// a modal, so the panel gets out of the way first; the login-item toggle doesn't, and
    /// leaves it open.
    func showAppMenu() {
        let entries = AppMenuBuilder.entries(windowController: windowController).map { entry -> AppMenuEntry in
            guard case let .action(title, key, handler) = entry else { return entry }
            return .action(title: title, key: key, handler: { [weak self] in
                self?.close()
                handler()
            })
        }
        AppMenuBuilder.menu(from: entries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - Clipboard

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(String(localized: "已复制\(label)"))
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

/// What a header chip narrows the list to. The cases mirror the chips one for one.
enum PanelFilter: Hashable {
    case running
    case stopped
    case transitioning
    case fatal
    case oneshotRunning

    func matches(_ snap: ProgramSnapshot) -> Bool {
        switch self {
        case .running:
            return snap.serviceState == .running
        case .stopped:
            return snap.serviceState == .stopped || snap.serviceState == .exited
        // Services that are neither settled-running nor settled-stopped. Without this the
        // chips silently dropped them: three services with one in BACKOFF read as
        // 「1 运行中 · 1 已停止」 and the third was simply missing from the tally.
        case .transitioning:
            return snap.serviceState == .starting || snap.serviceState == .backoff || snap.serviceState == .stopping
        case .fatal:
            return snap.serviceState == .fatal
        case .oneshotRunning:
            return snap.oneshotState == .running
        }
    }
}
