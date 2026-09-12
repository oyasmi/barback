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
    private var configSelection: Int64?
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
        if let id { configSelection = id }
        if configWindow == nil {
            let view = ConfigWindowView(appState: appState, initialSelection: configSelection)
            let window = makeWindow(title: "配置", size: NSSize(width: 900, height: 620), content: view)
            window.minSize = NSSize(width: 860, height: 600)
            window.delegate = self
            configWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        configWindow?.makeKeyAndOrderFront(nil)
    }

    func showLogWindow(programId: Int64) {
        guard let snap = appState.program(id: programId) else { return }
        if let existing = logWindows[programId] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let path = logPath(for: snap)
        let view = LogViewerView(programName: snap.program.name, path: path)
        let window = makeWindow(title: "日志 · \(snap.program.name)", size: NSSize(width: 760, height: 520), content: view)
        window.delegate = self
        logWindows[programId] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func logPath(for snap: ProgramSnapshot) -> String {
        if let explicit = snap.program.logPath { return explicit }
        if snap.program.kind == .oneshot, let last = snap.lastRun?.logPath { return last }
        return (AppPaths.programsLogsDir as NSString).appendingPathComponent("\(snap.program.name).out.log")
    }

    func revealLog(programId: Int64) {
        guard let snap = appState.program(id: programId) else { return }
        NSWorkspace.shared.selectFile(logPath(for: snap), inFileViewerRootedAtPath: "")
    }

    func showHistoryWindow(programId: Int64?) {
        if historyWindow == nil {
            let view = HistoryWindowView(appState: appState, initialProgramId: programId)
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
            let window = makeWindow(title: "偏好设置", size: NSSize(width: 520, height: 420), content: view)
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

    func toggleLoginItem() {
        LoginItemManager.setEnabled(!LoginItemManager.isRegistered)
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

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "barback-diagnostics.zip"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeDiagnostics(to: url)
        }
    }

    private func writeDiagnostics(to url: URL) {
        DiagnosticsExporter.export(appState: appState, to: url)
    }

    func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "Barback 不会自动更新；发现新版本时可在此手动检查。"
        alert.runModal()
    }

    func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate — closing a log window stops its file watch (design.md §4)

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === configWindow { configWindow = nil }
        if window === historyWindow { historyWindow = nil }
        if window === eventsWindow { eventsWindow = nil }
        if window === preferencesWindow { preferencesWindow = nil }
        if window === importWindow { importWindow = nil }
        if let id = logWindows.first(where: { $0.value === window })?.key {
            logWindows.removeValue(forKey: id)
        }
    }
}
