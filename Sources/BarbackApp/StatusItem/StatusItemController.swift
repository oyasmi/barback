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
        } else if snapshot.runningCount > 0 {
            symbolName = "wineglass.fill"
        } else {
            symbolName = "wineglass"
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
