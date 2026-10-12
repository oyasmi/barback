import AppKit

/// `NSMenuItem` that carries its own action closure so menu-building can stay inline.
final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    /// For a check-marked item: its state, read whenever AppKit validates the menu.
    var stateProvider: (() -> Bool)?

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

    /// The item is its own target, so AppKit asks it right before the menu is shown.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let stateProvider { menuItem.state = stateProvider() ? .on : .off }
        return true
    }
}
