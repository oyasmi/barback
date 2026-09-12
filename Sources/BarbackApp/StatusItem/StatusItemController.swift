import AppKit
import BarbackCore

/// Builds the two status-bar menus fresh each time they open (design.md §6.2) so idle
/// time costs nothing: no persistent menu object, no timer while closed.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let appState: AppState
    weak var windowController: WindowController?

    private var refreshTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = iconImage()
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleClick(_:))
        button.target = self
    }

    private func iconImage() -> NSImage? {
        let snapshot = appState.snapshot
        let symbolName: String
        if snapshot.fatalCount > 0 {
            symbolName = "exclamationmark.triangle.fill"
        } else if snapshot.oneshotRunningCount > 0 {
            symbolName = "circle.dotted"
        } else if snapshot.stoppedCount > 0 {
            symbolName = "cup.and.saucer"
        } else {
            symbolName = "cup.and.saucer.fill"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Barback")
        image?.isTemplate = true
        return image
    }

    func refreshIcon() {
        statusItem.button?.image = iconImage()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRight = event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        let menu = isRight ? buildAppMenu() : buildProgramMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - NSMenuDelegate — sampling only while a menu is actually open (design.md §6.2)

    func menuWillOpen(_ menu: NSMenu) {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickRefresh(menu: menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func tickRefresh(menu: NSMenu) {
        // Menu is already open with a fixed item set; live-updating text without rebuilding
        // the whole menu keeps this cheap. We only touch title strings for active rows.
        for item in menu.items {
            guard let id = item.representedObject as? Int64, let snap = appState.program(id: id) else { continue }
            item.title = ProgramMenuBuilder.titleLine(for: snap)
        }
    }

    // MARK: - Menu construction

    private func buildProgramMenu() -> NSMenu {
        ProgramMenuBuilder.build(appState: appState, windowController: windowController)
    }

    private func buildAppMenu() -> NSMenu {
        AppMenuBuilder.build(appState: appState, windowController: windowController)
    }
}
