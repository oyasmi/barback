import AppKit

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
