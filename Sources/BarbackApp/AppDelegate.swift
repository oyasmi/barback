import AppKit
import SwiftUI
import BarbackCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var supervisor: Supervisor!
    private var appState: AppState!
    private var statusItemController: StatusItemController!
    private var windowController: WindowController!
    private var onboardingWindow: NSWindow?
    private var isTerminating = false
    /// Last time each (program, notification kind) pair was posted, for APP-4 debouncing.
    private var lastNotified: [String: Date] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        do {
            try AppPaths.ensureDirectoriesExist()
            store = try Store(dbPath: AppPaths.dbPath, backupsDir: AppPaths.backupsDir)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法初始化数据库"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        supervisor = Supervisor(store: store)
        appState = AppState(supervisor: supervisor, store: store)
        windowController = WindowController(appState: appState)
        statusItemController = StatusItemController(appState: appState)
        statusItemController.windowController = windowController

        supervisor.onSnapshot = { [weak self] snapshot in
            self?.appState.snapshot = snapshot
            self?.statusItemController.refreshIcon()
        }
        // Both callbacks fire on the supervisor queue; hop to main before touching the
        // debounce table or AppKit.
        supervisor.onNotify = { [weak self] kind in
            DispatchQueue.main.async { self?.postNotification(for: kind) }
        }
        supervisor.onOneshotNotify = { [weak self] program, outcome, duration in
            DispatchQueue.main.async {
                self?.postOneshotNotification(program: program, outcome: outcome, duration: duration)
            }
        }

        // UNUserNotificationCenter requires a real .app bundle identity; guard so running
        // the raw binary during development doesn't crash (design.md §8.5 packaging step).
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil
        )

        supervisor.bootstrap()

        if !hasCompletedOnboarding {
            showOnboarding()
        }
    }

    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "barback.onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "barback.onboarded") }
    }

    private func showOnboarding() {
        let view = OnboardingWindowView(
            onOpenConfig: { [weak self] in self?.windowController.showConfigWindow() },
            onOpenImport: { [weak self] in self?.windowController.showImportWindow() },
            onFinish: { [weak self] in
                self?.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "欢迎使用 Barback"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func handleWake() {
        supervisor.reconcileAfterWake()
    }

    // MARK: - Notifications (design.md APP-4)

    private func postNotification(for kind: NotificationKind) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        let debounceKey: String
        switch kind {
        case .enteredFatal(let name):
            guard Preferences.notifyFatal else { return }
            debounceKey = "fatal:\(name)"
            content.title = "服务启动失败"
            content.body = "\(name) 已进入 FATAL 状态，重试已停止。"
        case .unexpectedRestart(let name):
            guard Preferences.notifyRestart else { return }
            debounceKey = "restart:\(name)"
            content.title = "服务已重启"
            content.body = "\(name) 意外退出，已自动重启。"
        case .stopTimeout(let name):
            // Grouped under the FATAL switch: both are "这个服务出问题了" alerts.
            guard Preferences.notifyFatal else { return }
            debounceKey = "stopTimeout:\(name)"
            content.title = "停止超时"
            content.body = "\(name) 未在期限内退出，已强制终止。"
        }
        guard passesDebounce(key: debounceKey) else { return }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func postOneshotNotification(program: Program, outcome: OneshotState, duration: TimeInterval) {
        guard Bundle.main.bundleIdentifier != nil, Preferences.notifyOneshot else { return }
        let content = UNMutableNotificationContent()
        content.title = program.name
        content.body = "\(outcome.displayText) · \(String(format: "%.1fs", duration))"
        // Deliberately not debounced: a one-shot only finishes because someone ran it, so
        // dropping the second result inside the window would just lose an answer.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Drops a repeat of the same service notification inside the debounce window, so a
    /// restart storm produces one banner instead of one per crash (requirements.md APP-4).
    private func passesDebounce(key: String) -> Bool {
        let now = Date()
        if let last = lastNotified[key], now.timeIntervalSince(last) < Preferences.notifyDebounce {
            return false
        }
        lastNotified[key] = now
        return true
    }

    // MARK: - Termination (design.md §3.6)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }

        supervisor.hasActiveOneshots { [weak self] hasActive in
            DispatchQueue.main.async {
                guard let self else { return }
                if hasActive {
                    let alert = NSAlert()
                    alert.messageText = "有一次性命令正在执行"
                    alert.informativeText = "退出将终止它们。"
                    alert.addButton(withTitle: "退出")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        NSApp.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
                self.isTerminating = true
                let progressWindow = TerminationProgressWindow.show()
                self.supervisor.stopAllForTermination {
                    progressWindow.close()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Minimal "stopping…" panel shown if shutdown takes over a second (design.md §3.6 step 3).
@MainActor
enum TerminationProgressWindow {
    static func show() -> NSWindow {
        let label = NSTextField(labelWithString: "正在停止所有被管进程…")
        label.frame = NSRect(x: 20, y: 20, width: 260, height: 24)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "正在退出"
        window.contentView?.addSubview(label)
        window.center()
        window.isReleasedWhenClosed = false
        // Only actually shown if termination takes noticeably long; ordering front now is
        // cheap and avoids a flash for the common fast-path case being visually jarring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if window.isVisible == false, window.isReleasedWhenClosed == false {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return window
    }
}
