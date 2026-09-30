import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` — a login item registration, not a LaunchAgent daemon.
/// If Barback crashes, the system will not relaunch it (design.md §8.5).
enum LoginItemManager {
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("LoginItemManager: \(error)")
        }
    }
}
