import AppKit
import BarbackCore

/// Builds the left-click menu: services section, one-shot commands section, global actions
/// (design.md §6.3). Rebuilt fresh on every open — no cached NSMenuItem graph to keep in sync.
@MainActor
enum ProgramMenuBuilder {
    static func build(appState: AppState, windowController: WindowController?) -> NSMenu {
        let menu = NSMenu()
        let snapshot = appState.snapshot

        let summary = "\(snapshot.runningCount) 运行 · \(snapshot.stoppedCount) 停止 · \(snapshot.fatalCount) 失败"
        let summaryItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)

        if snapshot.recoveredCount > 0 {
            menu.addItem(NSMenuItem(title: "上次异常退出，已恢复 \(snapshot.recoveredCount) 项", action: nil, keyEquivalent: ""))
        }

        let services = snapshot.programs.filter { $0.program.kind == .service }
        let oneshots = snapshot.programs.filter { $0.program.kind == .oneshot }

        if !services.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("服务"))
            for group in groupedByName(services) {
                if let groupName = group.groupName {
                    menu.addItem(sectionHeader(groupName, indent: 1))
                }
                for snap in group.items {
                    menu.addItem(serviceItem(snap, appState: appState, windowController: windowController))
                }
            }
        }

        if !oneshots.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("一次性命令"))
            for snap in oneshots {
                menu.addItem(oneshotItem(snap, appState: appState, windowController: windowController))
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("全部启动") { appState.supervisor.startAll() })
        menu.addItem(actionItem("全部停止") { appState.supervisor.stopAll() })
        menu.addItem(actionItem("全部重启") { appState.supervisor.restartAll() })

        menu.addItem(.separator())
        let configItem = actionItem("打开配置窗口…") { windowController?.showConfigWindow() }
        configItem.keyEquivalent = ","
        configItem.keyEquivalentModifierMask = [.command]
        menu.addItem(configItem)

        return menu
    }

    private struct Group { let groupName: String?; let items: [ProgramSnapshot] }

    private static func groupedByName(_ items: [ProgramSnapshot]) -> [Group] {
        guard items.count > 12 else { return [Group(groupName: nil, items: items)] }
        var order: [String] = []
        var buckets: [String: [ProgramSnapshot]] = [:]
        for item in items {
            let key = item.program.groupName ?? "默认"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { Group(groupName: $0, items: buckets[$0] ?? []) }
    }

    private static func sectionHeader(_ text: String, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: String(repeating: "  ", count: indent) + text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func titleLine(for snap: ProgramSnapshot) -> String {
        "\(statusGlyph(snap)) \(snap.program.name)  \(snap.statusText)"
    }

    private static func statusGlyph(_ snap: ProgramSnapshot) -> String {
        if let s = snap.serviceState {
            switch s {
            case .running: return "●"
            case .starting, .backoff: return "◐"
            case .fatal: return "⚠"
            default: return "○"
            }
        }
        if snap.oneshotState == .running { return "◌" }
        return "▶"
    }

    private static func serviceItem(_ snap: ProgramSnapshot, appState: AppState, windowController: WindowController?) -> NSMenuItem {
        let item = NSMenuItem(title: titleLine(for: snap), action: nil, keyEquivalent: "")
        item.representedObject = snap.id
        item.submenu = serviceSubmenu(snap, appState: appState, windowController: windowController)
        return item
    }

    private static func serviceSubmenu(_ snap: ProgramSnapshot, appState: AppState, windowController: WindowController?) -> NSMenu {
        let menu = NSMenu()
        let id = snap.id
        let supervisor = appState.supervisor
        let optionHeld = NSEvent.modifierFlags.contains(.option)

        let startItem = actionItem("启动") { supervisor.start(id: id) }
        startItem.isEnabled = !(snap.serviceState?.isActive ?? false)
        menu.addItem(startItem)

        let stopItem = actionItem("停止") { supervisor.stop(id: id) }
        stopItem.isEnabled = snap.serviceState?.isActive ?? false
        menu.addItem(stopItem)

        let restartItem = actionItem("重启") { supervisor.restart(id: id) }
        restartItem.keyEquivalent = "r"
        restartItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(restartItem)

        if snap.serviceState == .fatal {
            menu.addItem(actionItem("清除失败状态") { supervisor.clearFatal(id: id) })
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("查看日志…") { windowController?.showLogWindow(programId: id) })
        menu.addItem(actionItem("在 Finder 中显示日志") { windowController?.revealLog(programId: id) })
        if let pid = snap.pid {
            menu.addItem(actionItem("复制 PID (\(pid))") { copyToPasteboard("\(pid)") })
        }

        menu.addItem(.separator())
        if let pid = snap.pid {
            let sample = ProcSampler.sample(pid: pid)
            let cpu = sample.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "—"
            let rss = sample.map { "\($0.rssBytes / 1_048_576) MB" } ?? "—"
            menu.addItem(sectionHeader("PID \(pid) · CPU \(cpu) · \(rss)"))
        }
        if let startedAt = snap.startedAt {
            menu.addItem(sectionHeader("启动于 \(formatDate(startedAt))"))
        }
        menu.addItem(sectionHeader("近期重启 \(snap.retryCount) 次"))

        menu.addItem(.separator())
        menu.addItem(actionItem("编辑配置…") { windowController?.showConfigWindow(selecting: id) })

        if optionHeld {
            menu.addItem(.separator())
            menu.addItem(actionItem("强制终止") { supervisor.forceKill(id: id) })
            menu.addItem(actionItem("复制启动命令") { copyToPasteboard(snap.program.command) })
        }

        return menu
    }

    private static func oneshotItem(_ snap: ProgramSnapshot, appState: AppState, windowController: WindowController?) -> NSMenuItem {
        let lastResult = snap.lastRun.map { run -> String in
            let outcome = run.outcome?.rawValue ?? "?"
            let duration = run.duration.map { String(format: "%.1fs", $0) } ?? ""
            return "上次 \(outcome) · \(formatDate(run.startedAt)) · \(duration)"
        } ?? "尚未执行"
        let item = NSMenuItem(title: "\(snap.program.name)  \(snap.oneshotState == .running ? "执行中" : lastResult)", action: nil, keyEquivalent: "")
        item.representedObject = snap.id
        item.submenu = oneshotSubmenu(snap, appState: appState, windowController: windowController, lastResult: lastResult)
        return item
    }

    private static func oneshotSubmenu(_ snap: ProgramSnapshot, appState: AppState, windowController: WindowController?, lastResult: String) -> NSMenu {
        let menu = NSMenu()
        let id = snap.id
        let supervisor = appState.supervisor

        let runItem = actionItem("运行") {
            if snap.program.confirmBeforeRun {
                windowController?.confirmRun(programId: id)
            } else {
                supervisor.runOneshot(id: id)
            }
        }
        runItem.isEnabled = snap.oneshotState != .running || snap.program.allowConcurrent
        menu.addItem(runItem)

        let cancelItem = actionItem("中止") { supervisor.cancelOneshot(id: id) }
        cancelItem.isEnabled = snap.oneshotState == .running
        menu.addItem(cancelItem)

        menu.addItem(.separator())
        menu.addItem(actionItem("查看本次输出…") { windowController?.showLogWindow(programId: id) })
        menu.addItem(actionItem("执行历史…") { windowController?.showHistoryWindow(programId: id) })

        menu.addItem(.separator())
        menu.addItem(sectionHeader(lastResult))
        menu.addItem(sectionHeader("共执行 \(snap.runCount) 次"))

        menu.addItem(.separator())
        menu.addItem(actionItem("编辑配置…") { windowController?.showConfigWindow(selecting: id) })

        return menu
    }

    private static func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        return item
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// `NSMenuItem` that carries its own action closure so menu-building can stay inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, handler: action)
    }

    required init(coder: NSCoder) {
        fatalError("not supported")
    }

    @objc private func fire() {
        handler()
    }
}
