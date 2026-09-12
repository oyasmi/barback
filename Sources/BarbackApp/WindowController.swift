import AppKit
import SwiftUI
import BarbackCore
import UserNotifications

/// Owns every non-status-bar window. Windows are created lazily on first show and kept
/// around (design.md §6.6 windows are opened on demand); closing a log window tears down
/// its file-watching per §4 "关窗即停止监听".
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var configWindow: NSWindow?
    private var configModel: ConfigWindowModel?
    private var historyWindow: NSWindow?
    private var eventsWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var importWindow: NSWindow?
    private var logWindows: [Int64: NSWindow] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.setContentSize(size)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func showConfigWindow(selecting id: Int64? = nil) {
        if let window = configWindow {
            if let id { configModel?.attempt(.select(id)) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = ConfigWindowModel(appState: appState, initialSelection: id)
        let view = ConfigWindowView(
            model: model,
            appState: appState,
            onShowLog: { [weak self] in self?.showLogWindow(programId: $0) },
            onShowHistory: { [weak self] in self?.showHistoryWindow(programId: $0) },
            onShowImport: { [weak self] in self?.showImportWindow() }
        )
        let window = makeWindow(title: "配置", size: NSSize(width: 980, height: 680), content: view)
        window.minSize = NSSize(width: 840, height: 560)
        window.toolbarStyle = .unified
        window.delegate = self
        // The close box grows a dot while a draft is unsaved, matching document windows.
        model.onDirtyChange = { [weak window] isDirty in window?.isDocumentEdited = isDirty }
        configWindow = window
        configModel = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showLogWindow(programId: Int64) {
        guard let snap = appState.program(id: programId) else { return }
        if let existing = logWindows[programId] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = LogViewerView(programName: snap.program.name, path: ProgramLogPath.resolve(for: snap))
        let window = makeWindow(title: "日志 · \(snap.program.name)", size: NSSize(width: 760, height: 520), content: view)
        window.delegate = self
        logWindows[programId] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func revealLog(programId: Int64) {
        guard let snap = appState.program(id: programId) else { return }
        NSWorkspace.shared.selectFile(ProgramLogPath.resolve(for: snap), inFileViewerRootedAtPath: "")
    }

    func showHistoryWindow(programId: Int64?) {
        if historyWindow == nil {
            let view = HistoryWindowView(
                appState: appState,
                initialProgramId: programId,
                onRerun: { [weak self] id in self?.runOneshotRespectingConfirm(programId: id) }
            )
            let window = makeWindow(title: "执行历史", size: NSSize(width: 820, height: 520), content: view)
            window.delegate = self
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    func showEventsWindow() {
        if eventsWindow == nil {
            let view = EventsWindowView(appState: appState)
            let window = makeWindow(title: "事件日志", size: NSSize(width: 820, height: 520), content: view)
            window.delegate = self
            eventsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        eventsWindow?.makeKeyAndOrderFront(nil)
    }

    func showPreferencesWindow() {
        if preferencesWindow == nil {
            let view = PreferencesWindowView(appState: appState)
            let window = makeWindow(title: "偏好设置", size: NSSize(width: 480, height: 520), content: view)
            window.delegate = self
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    func showImportWindow() {
        if importWindow == nil {
            let view = ImportWindowView(appState: appState, onClose: { [weak self] in self?.importWindow?.close() })
            let window = makeWindow(title: "从 supervisor 粘贴导入", size: NSSize(width: 720, height: 560), content: view)
            window.delegate = self
            importWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        importWindow?.makeKeyAndOrderFront(nil)
    }

    func confirmRun(programId: Int64) {
        guard let snap = appState.program(id: programId) else { return }
        let alert = NSAlert()
        alert.messageText = "运行「\(snap.program.name)」？"
        alert.informativeText = "该命令已标记为需要确认。"
        alert.addButton(withTitle: "运行")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.supervisor.runOneshot(id: programId)
        }
    }

    /// The single place a one-shot gets (re)started from outside the status panel, so the
    /// `confirmBeforeRun` gate applies no matter which window asked for it (design.md CFG-4).
    func runOneshotRespectingConfirm(programId: Int64) {
        guard let snap = appState.program(id: programId), snap.program.kind == .oneshot else { return }
        if snap.program.confirmBeforeRun {
            confirmRun(programId: programId)
        } else {
            appState.supervisor.runOneshot(id: programId)
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "barback-diagnostics.md"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeDiagnostics(to: url)
        }
    }

    private func writeDiagnostics(to url: URL) {
        DiagnosticsExporter.export(appState: appState, to: url)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate — closing a log window stops its file watch (design.md §4)

    /// Closing the config window with an unsaved draft asks first (design.md §6.5), the same
    /// gate the in-window selection change goes through.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === configWindow, let model = configModel, model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "「\(model.draft?.name ?? "")」有未保存的更改"
        alert.informativeText = "关闭窗口前要保存这些更改吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save(restart: false) { [weak self] succeeded in
                guard succeeded else { return } // validation failed: errors are now on the form
                self?.configWindow?.close()
            }
            return false
        case .alertSecondButtonReturn:
            model.discardDraft()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === configWindow {
            configWindow = nil
            configModel = nil
        }
        if window === historyWindow { historyWindow = nil }
        if window === eventsWindow { eventsWindow = nil }
        if window === preferencesWindow { preferencesWindow = nil }
        if window === importWindow { importWindow = nil }
        if let id = logWindows.first(where: { $0.value === window })?.key {
            logWindows.removeValue(forKey: id)
        }
    }
}
