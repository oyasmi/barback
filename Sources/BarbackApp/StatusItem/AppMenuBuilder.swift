import AppKit
import BarbackCore

/// Right-click menu: Barback's own functions, disjoint from the left-click program menu
/// (design.md §6.4).
@MainActor
enum AppMenuBuilder {
    static func build(appState: AppState, windowController: WindowController?) -> NSMenu {
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let uptime = formatUptime(ProcessInfo.processInfo.systemUptime - AppLaunchClock.launchUptime)
        let header = NSMenuItem(title: "Barback \(version) (\(build)) · 已运行 \(uptime)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let configItem = ClosureMenuItem(title: "打开配置窗口…") { windowController?.showConfigWindow() }
        configItem.keyEquivalent = ","
        configItem.keyEquivalentModifierMask = [.command]
        menu.addItem(configItem)
        menu.addItem(ClosureMenuItem(title: "执行历史…") { windowController?.showHistoryWindow(programId: nil) })
        menu.addItem(ClosureMenuItem(title: "事件日志…") { windowController?.showEventsWindow() })
        menu.addItem(ClosureMenuItem(title: "打开日志目录") { NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.logsDir)) })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "偏好设置…") { windowController?.showPreferencesWindow() })
        let autostartItem = ClosureMenuItem(title: "开机自动启动") { windowController?.toggleLoginItem() }
        autostartItem.state = LoginItemManager.isRegistered ? .on : .off
        menu.addItem(autostartItem)
        menu.addItem(ClosureMenuItem(title: "从 supervisor 粘贴导入…") { windowController?.showImportWindow() })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "导出诊断包…") { windowController?.exportDiagnostics() })
        menu.addItem(ClosureMenuItem(title: "检查更新…") { windowController?.checkForUpdates() })
        menu.addItem(ClosureMenuItem(title: "关于 Barback") { windowController?.showAboutPanel() })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "退出 Barback（将停止全部被管进程）") { windowController?.quitApp() })

        return menu
    }

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分钟" }
        return "\(m)分钟"
    }
}

enum AppLaunchClock {
    static let launchUptime = ProcessInfo.processInfo.systemUptime
}
