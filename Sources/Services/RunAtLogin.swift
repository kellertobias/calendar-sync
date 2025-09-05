import Foundation
import ServiceManagement

/// Minimal facade around ServiceManagement's login-item API.
///
/// Why: Centralize logic to enable/disable "Run at Login" and to read current status.
/// How: Uses `SMAppService.mainApp` (macOS 13+) to register/unregister the main app as a login item.
@MainActor
enum RunAtLogin {
    /// Returns whether the app is currently configured to launch at login.
    static func isEnabled() -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled: return true
        default: return false
        }
    }

    /// Enables or disables launching the app at login.
    /// - Parameter enabled: When true, registers the main app; otherwise unregisters it.
    /// - Throws: Any error from ServiceManagement when registration fails (e.g., permissions).
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}


