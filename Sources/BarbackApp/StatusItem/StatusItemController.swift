import AppKit
import SwiftUI
import BarbackCore

/// Owns the status item and its two click targets: a SwiftUI panel on the left, the
/// app-level `NSMenu` on the right (design.md §6.2).
///
/// Both are built only when opened and dropped when closed — the panel's per-second
/// sampling therefore exists exactly while it is on screen, which is what keeps idle cost
/// at zero (design.md §6.2 常态零开销).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let appState: AppState
    weak var windowController: WindowController?

    private var popover: NSPopover?
    private var panelModel: StatusPanelModel?
    /// So `refreshIcon` — called on every snapshot publish — can skip rebuilding an `NSImage`
    /// (one of the pricier Foundation/AppKit objects to construct) when the icon wouldn't
    /// actually change, which is most of the time (design.md §6.2, ex-F20).
    private var lastIconSymbol: String?

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleClick(_:))
        button.target = self
        refreshIcon()
    }

    private func symbolName(for snapshot: SupervisorSnapshot) -> String {
        if snapshot.fatalCount > 0 {
            return "exclamationmark.triangle.fill"
        } else if snapshot.oneshotRunningCount > 0 {
            return "circle.dotted"
        } else if snapshot.runningCount > 0 {
            return "wineglass.fill"
        } else {
            return "wineglass"
        }
    }

    func refreshIcon() {
        let symbol = symbolName(for: appState.snapshot)
        guard symbol != lastIconSymbol else { return }
        lastIconSymbol = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Barback")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRight = event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRight {
            showAppMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - Left click: the program panel

    private func togglePanel() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }

        let model = StatusPanelModel(appState: appState, windowController: windowController)
        model.onRequestClose = { [weak self] in self?.closePanel() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: StatusPanelView(appState: appState, model: model)
        )
        self.popover = popover
        self.panelModel = model

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the panel's buttons would need a click to focus the window first.
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        model.startTicking()
        // Cheap liveness re-check right when someone is about to look at the panel, per
        // design.md's own suggestion for this safety net (ex-F25).
        appState.supervisor.reconcileNow()
    }

    private func closePanel() {
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        panelModel?.stopTicking()
        panelModel = nil
        popover?.contentViewController = nil
        popover = nil
        statusItem.button?.highlight(false)
    }

    // MARK: - Right click: the app menu

    private func showAppMenu() {
        closePanel()
        let menu = AppMenuBuilder.build(appState: appState, windowController: windowController)
        // Handing the menu to the status item (rather than popping it up directly) keeps the
        // button's highlight in sync; it is removed again so the next click still runs `action`.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
