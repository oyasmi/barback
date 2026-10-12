import AppKit
import BarbackCore

/// Application menus, shared by the status item's right-click menu and the main menu.
@MainActor
enum AppMenuBuilder {
    /// A programmatically launched app has no nib-provided Edit menu. Install one
    /// so AppKit routes editing shortcuts to the focused control in every window.
    static func buildMainMenu(appState: AppState, windowController: WindowController) -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Barback", action: nil, keyEquivalent: "")
        appItem.submenu = build(appState: appState, windowController: windowController)
        menu.addItem(appItem)

        let editMenu = NSMenu(title: String(localized: "编辑"))
        let commands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            (String(localized: "撤销"), Selector(("undo:")), "z", [.command]),
            (String(localized: "重做"), Selector(("redo:")), "z", [.command, .shift]),
            (String(localized: "剪切"), #selector(NSText.cut(_:)), "x", [.command]),
            (String(localized: "复制"), #selector(NSText.copy(_:)), "c", [.command]),
            (String(localized: "粘贴"), #selector(NSText.paste(_:)), "v", [.command]),
            (String(localized: "全选"), #selector(NSText.selectAll(_:)), "a", [.command])
        ]
        for (title, action, key, modifiers) in commands {
            if key == "x" { editMenu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            // A nil target lets the responder chain find the active text editor.
            item.target = nil
            editMenu.addItem(item)
        }
        let editItem = NSMenuItem(title: String(localized: "编辑"), action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        return menu
    }

    static func build(appState: AppState, windowController: WindowController?) -> NSMenu {
        menu(from: entries(windowController: windowController))
    }

    static func menu(from entries: [AppMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case let .action(title, key, handler):
                let item = ClosureMenuItem(title: title, handler: handler)
                if let key {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = [.command]
                }
                menu.addItem(item)
            case let .toggle(title, isOn, handler):
                let item = ClosureMenuItem(title: title, handler: handler)
                // Re-read on every validation pass: the main menu is built once at launch and
                // would otherwise keep whatever the login item was back then.
                item.stateProvider = isOn
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    /// The app menu as data, so the status item's right-click menu and the panel's ⋯ button
    /// list the same things in the same order (design.md §6.4) while the panel can still wrap
    /// each action to close itself first.
    static func entries(windowController: WindowController?) -> [AppMenuEntry] {
        [
            .action(title: String(localized: "关于 Barback"), handler: { windowController?.showAboutWindow() }),
            .separator,
            .action(title: String(localized: "打开配置窗口"), key: ",", handler: { windowController?.showConfigWindow() }),
            .action(title: String(localized: "执行历史"), handler: { windowController?.showHistoryWindow(programId: nil) }),
            .action(title: String(localized: "事件日志"), handler: { windowController?.showEventsWindow() }),
            .action(title: String(localized: "打开日志目录"), handler: { NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.logsDir)) }),
            .separator,
            .action(title: String(localized: "偏好设置"), handler: { windowController?.showPreferencesWindow() }),
            .toggle(title: String(localized: "开机自动启动"),
                    isOn: { LoginItemManager.isRegistered },
                    handler: { LoginItemManager.setEnabled(!LoginItemManager.isRegistered) }),
            .action(title: String(localized: "从 supervisor 粘贴导入"), handler: { windowController?.showImportWindow() }),
            .separator,
            .action(title: String(localized: "导出诊断包"), handler: { windowController?.exportDiagnostics() }),
            .separator,
            // The parenthetical stays: quitting only asks about in-flight one-shots, so this
            // title is the one warning that every service goes down with the app.
            .action(title: String(localized: "退出 Barback（将停止全部被管进程）"), key: "q", handler: { windowController?.quitApp() })
        ]
    }
}

/// One line of the app menu (see `AppMenuBuilder.entries`).
enum AppMenuEntry {
    /// `key` is a ⌘ key equivalent.
    case action(title: String, key: String? = nil, handler: () -> Void)
    /// A check-marked item; `isOn` is asked each time the menu is shown.
    case toggle(title: String, isOn: () -> Bool, handler: () -> Void)
    case separator
}
