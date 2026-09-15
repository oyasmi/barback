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

        let editMenu = NSMenu(title: "编辑")
        let commands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("撤销", Selector(("undo:")), "z", [.command]),
            ("重做", Selector(("redo:")), "z", [.command, .shift]),
            ("剪切", #selector(NSText.cut(_:)), "x", [.command]),
            ("复制", #selector(NSText.copy(_:)), "c", [.command]),
            ("粘贴", #selector(NSText.paste(_:)), "v", [.command]),
            ("全选", #selector(NSText.selectAll(_:)), "a", [.command])
        ]
        for (title, action, key, modifiers) in commands {
            if key == "x" { editMenu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            // A nil target lets the responder chain find the active text editor.
            item.target = nil
            editMenu.addItem(item)
        }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        return menu
    }

    static func build(appState: AppState, windowController: WindowController?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "关于 Barback") { windowController?.showAboutWindow() })
        menu.addItem(.separator())

        let configItem = ClosureMenuItem(title: "打开配置窗口") { windowController?.showConfigWindow() }
        configItem.keyEquivalent = ","
        configItem.keyEquivalentModifierMask = [.command]
        menu.addItem(configItem)
        menu.addItem(ClosureMenuItem(title: "执行历史") { windowController?.showHistoryWindow(programId: nil) })
        menu.addItem(ClosureMenuItem(title: "事件日志") { windowController?.showEventsWindow() })
        menu.addItem(ClosureMenuItem(title: "打开日志目录") { NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.logsDir)) })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "偏好设置") { windowController?.showPreferencesWindow() })
        menu.addItem(ClosureMenuItem(title: "从 supervisor 粘贴导入") { windowController?.showImportWindow() })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "导出诊断包") { windowController?.exportDiagnostics() })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "退出 Barback（将停止全部被管进程）") { windowController?.quitApp() })

        return menu
    }
}
