import AppKit
import SwiftUI
import BarbackCore

/// Owns the status item and its two click targets: a SwiftUI panel on the left, the
/// app-level `NSMenu` on the right (design.md §6.2).
///
    /// Both are built only when opened and dropped when closed — the panel's periodic
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
    private var lastIcon: IconState?
    /// Installed only while the panel is on screen. SwiftUI in a popover never gets a first
    /// responder of its own for anything but the search field, so arrow-key navigation has to
    /// come from AppKit (BAR-10).
    private var keyMonitor: Any?

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

    // MARK: - Icon (design.md §6.1)

    /// What the menu-bar glyph says. The glass is always the glass — swapping it wholesale for
    /// a warning triangle or a dotted circle, as it used to, left a status item nobody could
    /// recognise as Barback at exactly the moment it wanted attention. State rides on a badge
    /// in the corner instead.
    private struct IconState: Equatable {
        enum Badge: Equatable {
            /// FATAL, or a one-shot whose last run failed or timed out. Red, and not a
            /// template, so it survives the menu bar's monochrome.
            case failure
            /// A one-shot is executing. Blue, matching the panel's execution state.
            case busy
            /// A service meant to be up (enabled + autostart) is stopped or has exited.
            /// Monochrome ring: worth noticing, not alarming.
            case stopped
        }

        var filled: Bool
        var badge: Badge?
    }

    private func iconState(for snapshot: SupervisorSnapshot) -> IconState {
        let programs = snapshot.programs
        let failing = programs.contains { snap in
            if snap.serviceState == .fatal { return true }
            return snap.hasOneshotProblem
        }
        let badge: IconState.Badge?
        if failing {
            badge = .failure
        } else if snapshot.oneshotRunningCount > 0 {
            badge = .busy
        } else if programs.contains(where: { snap in
            snap.program.kind == .service && snap.program.enabled && snap.program.autostart
                && (snap.serviceState == .stopped || snap.serviceState == .exited)
        }) {
            badge = .stopped
        } else {
            badge = nil
        }
        return IconState(filled: snapshot.runningCount > 0, badge: badge)
    }

    func refreshIcon() {
        let state = iconState(for: appState.snapshot)
        guard state != lastIcon else { return }
        lastIcon = state
        statusItem.button?.image = Self.makeIcon(state)
    }

    private static func makeIcon(_ state: IconState) -> NSImage? {
        guard let glass = NSImage(systemSymbolName: state.filled ? "wineglass.fill" : "wineglass",
                                  accessibilityDescription: "Barback") else { return nil }
        guard let badge = state.badge else {
            glass.isTemplate = true
            return glass
        }

        let dot: CGFloat = 6
        let size = NSSize(width: glass.size.width + 2, height: glass.size.height)
        let badgeRect = NSRect(x: size.width - dot, y: 0, width: dot, height: dot)
        // A colour badge means the image can't be a template, so the glass has to be inked by
        // hand. The handler runs at draw time with the button's appearance current, so
        // `labelColor` resolves to the menu bar's light or dark ink, and AppKit re-runs it
        // when that appearance changes.
        let isTemplate = badge == .stopped
        let image = NSImage(size: size, flipped: false) { _ in
            let glassRect = NSRect(origin: .zero, size: glass.size)
            glass.draw(in: glassRect)
            (isTemplate ? NSColor.black : NSColor.labelColor).set()
            glassRect.fill(using: .sourceAtop)

            // Knock a gap around the badge so it reads as separate from the glass's foot.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            switch badge {
            case .failure:
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            case .busy:
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            case .stopped:
                NSColor.black.setStroke()
                let ring = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "Barback"
        return image
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
        installKeyMonitor()
        model.startTicking()
        // Cheap liveness re-check right when someone is about to look at the panel, per
        // design.md's own suggestion for this safety net (ex-F25).
        appState.supervisor.reconcileNow()
    }

    private func closePanel() {
        popover?.performClose(nil)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors are always delivered on the main thread; `assumeIsolated` is how
            // the rest of this codebase states that to the compiler. NSEvent isn't Sendable, so
            // the isolated closure returns a Bool instead of the event itself.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                // Scoped to the open panel: a monitor left armed would swallow arrow keys in
                // the config window too.
                guard let self, self.popover?.isShown == true,
                      event.window === self.popover?.contentViewController?.view.window,
                      let model = self.panelModel else { return false }
                // IME candidate navigation and confirmation belong to the field editor.
                if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                return model.handleKeyDown(event)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        removeKeyMonitor()
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
