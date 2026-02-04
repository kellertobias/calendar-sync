import AppKit
import EventKit
import Foundation
import OSLog

/// Observable authorization helper for EventKit calendar and reminder access.
/// Why: Centralizes permission status, requests, and deep links to System Settings for the UI.
/// How: Uses modern macOS 14+ APIs (`requestFullAccessToEvents` / `requestWriteOnlyAccessToEvents`) and
///      surfaces read/write capability so the UI can guide the user.
/// Troubleshooting:
/// - Ensure `Config/Info.plist` contains `NSCalendarsUsageDescription` and the macOS 14+ keys
///   `NSCalendarsFullAccessUsageDescription` and `NSCalendarsWriteOnlyAccessUsageDescription`.
/// - Ensure entitlements enable App Sandbox and `com.apple.security.personal-information.calendars`.
/// - Status can remain `.notDetermined` until one of the request APIs is called.
/// - Some systems update status asynchronously; we refresh immediately and after a short delay.
final class EventKitAuth: ObservableObject {
  @Published private(set) var status: EKAuthorizationStatus = .notDetermined
  @Published private(set) var reminderStatus: EKAuthorizationStatus = .notDetermined
  private var store = EKEventStore()
  /// Prevents multiple auto-relaunch attempts in a single process lifetime.
  private var didAutoRelaunch: Bool = false

  init() {
    refreshStatus()
  }

  /// Refreshes the cached authorization status for both calendars and reminders.
  /// - Why: Status can change externally in System Settings.
  func refreshStatus() {
    status = EKEventStore.authorizationStatus(for: .event)
    reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
    NSLog(
      "EventKitAuth.refreshStatus -> calendar status=\(status.rawValue), reminder status=\(reminderStatus.rawValue)"
    )
  }

  /// Requests full read/write access to calendars (macOS 14+).
  /// - Parameter completion: Invoked on main queue after system prompt resolves.
  func requestFullAccess(completion: (() -> Void)? = nil) {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "Auth")
    logger.info("requestFullAccess called. Current status: \(self.status.rawValue)")
    
    // Reset the store to ensure we aren't using a cached permission state.
    // This is expensive but necessary if the app state is stale regarding TCC.
    store = EKEventStore()
    
    let hadReadAccessBefore = hasReadAccess
    // Prefer modern API on macOS 14+, but fall back to legacy API if needed.
    if #available(macOS 14.0, *) {
      logger.info("Using macOS 14+ requestFullAccessToEvents")
      store.requestFullAccessToEvents { [weak self] granted, error in
        logger.info("requestFullAccessToEvents completed. Granted: \(granted), Error: \(String(describing: error))")
        DispatchQueue.main.async {
          guard let self else { return }
          if let error {
            NSLog("EventKitAuth.requestFullAccess error: \(error.localizedDescription)")
          }
          NSLog(
            "EventKitAuth.requestFullAccess granted=\(granted), status(before)=\(self.status.rawValue)"
          )
          self.refreshStatus()
          NSApplication.shared.activate(ignoringOtherApps: true)
          // Re-check a few times to catch delayed TCC updates
          let delays: [TimeInterval] = [0.3, 1.0, 2.0]
          for (idx, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
              self.refreshStatus()
              // If we transitioned into read access, relaunch once to ensure entitlements are fully honored.
              if !hadReadAccessBefore && self.hasReadAccess {
                self.scheduleRelaunchIfNeeded(reason: "permission_granted_#\(idx)")
              }
            }
          }
          completion?()
        }
      }
    } else {
      logger.info("Using legacy requestAccess(to: .event)")
      store.requestAccess(to: .event) { [weak self] granted, error in
        logger.info("requestAccess completed. Granted: \(granted), Error: \(String(describing: error))")
        DispatchQueue.main.async {
          if let error {
            NSLog("EventKitAuth.requestAccess (legacy) error: \(error.localizedDescription)")
          }
          NSLog("EventKitAuth.requestAccess (legacy) granted=\(granted)")
          self?.refreshStatus()
          if let self, !hadReadAccessBefore && self.hasReadAccess {
            self.scheduleRelaunchIfNeeded(reason: "permission_granted_legacy")
          }
          completion?()
        }
      }
    }
  }

  /// Requests write-only access (no read). Not sufficient for building sync plans.
  /// - Parameter completion: Invoked on main queue after system prompt resolves.
  func requestWriteOnly(completion: (() -> Void)? = nil) {
    store.requestWriteOnlyAccessToEvents { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.refreshStatus()
        completion?()
      }
    }
  }

  /// Requests access to reminders for task synchronization.
  /// - Parameter completion: Invoked on main queue after system prompt resolves.
  func requestReminderAccess(completion: (() -> Void)? = nil) {
    store.requestAccess(to: .reminder) { [weak self] granted, error in
      DispatchQueue.main.async {
        if let error {
          NSLog("EventKitAuth.requestReminderAccess error: \(error.localizedDescription)")
        }
        NSLog("EventKitAuth.requestReminderAccess granted=\(granted)")
        self?.refreshStatus()
        completion?()
      }
    }
  }

  /// Attempts to open System Settings at Privacy → Calendars.
  func openSystemSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    else { return }
    NSWorkspace.shared.open(url)
    // After opening Settings, poll a few times briefly to reflect user changes without restart.
    let delays: [TimeInterval] = [0.5, 2.0, 5.0]
    for delay in delays {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        self.refreshStatus()
        // If status transitioned here while the user toggled privacy, schedule one-time relaunch.
        if self.hasReadAccess { self.scheduleRelaunchIfNeeded(reason: "settings_opened_refresh") }
      }
    }
  }

  /// Whether we currently have read access to events (required to build plans).
  var hasReadAccess: Bool {
    switch status {
    case .authorized, .fullAccess: return true
    default: return false
    }
  }

  /// Whether we currently have write capability (required to apply plans).
  var hasWriteAccess: Bool {
    switch status {
    case .authorized, .fullAccess, .writeOnly: return true
    default: return false
    }
  }

  /// Whether we currently have read access to reminders (required for task sync).
  var hasReminderAccess: Bool {
    switch reminderStatus {
    case .authorized, .fullAccess: return true
    default: return false
    }
  }

  /// Human-readable status for display.
  var statusDescription: String {
    switch status {
    case .notDetermined: return "Not Determined"
    case .restricted: return "Restricted"
    case .denied: return "Denied"
    case .authorized: return "Authorized (Legacy)"
    case .fullAccess: return "Full Access"
    case .writeOnly: return "Write Only"
    @unknown default: return "Unknown"
    }
  }

  /// Human-readable reminder status for display.
  var reminderStatusDescription: String {
    switch reminderStatus {
    case .notDetermined: return "Not Determined"
    case .restricted: return "Restricted"
    case .denied: return "Denied"
    case .authorized: return "Authorized"
    case .fullAccess: return "Full Access"
    @unknown default: return "Unknown"
    }
  }
}

extension EventKitAuth {
  /// Schedules a one-time relaunch of the current bundle to ensure
  /// newly granted permissions are applied to a fresh process.
  /// - Parameter reason: Optional tag for logging.
  fileprivate func scheduleRelaunchIfNeeded(reason: String) {
    // Only relaunch after we truly have read access; avoid loops or premature exits.
    guard hasReadAccess, !didAutoRelaunch else { return }
    didAutoRelaunch = true
    NSLog("EventKitAuth.scheduleRelaunchIfNeeded triggered (reason=\(reason))")
    // Give the UI a moment to reflect the new state, then relaunch.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      let bundleURL = Bundle.main.bundleURL
      let config = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
        NSApplication.shared.terminate(nil)
      }
    }
  }
}
