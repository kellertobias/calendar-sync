import Foundation
import OSLog
import AppKit

/// Scheduler that monitors system wake and unlock events to trigger CapEx script submission
/// when the configured schedule conditions are met.
@MainActor
final class CapExSubmissionScheduler: ObservableObject {
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "CapExScheduler")
  private let submissionService = CapExSubmissionService()
  private weak var appState: AppState?
  private var modelContext: Any?  // SwiftData.ModelContext - using Any to avoid import issues
  
  /// Whether the scheduler is actively monitoring for wake/unlock events.
  @Published var isActive: Bool = false
  
  init() {}
  
  /// Configures the scheduler with required dependencies and starts monitoring.
  func configure(appState: AppState) {
    self.appState = appState
    startMonitoring()
  }
  
  /// Begins listening for system wake and screen unlock notifications.
  func startMonitoring() {
    guard !isActive else { return }
    isActive = true
    
    // Monitor system wake
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(systemDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    
    // Monitor screen unlock (via screenDidWake or screensDidUnlock)
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(screenDidUnlock),
      name: NSNotification.Name("com.apple.screenIsUnlocked"),
      object: nil
    )
    
    logger.info("CapEx submission scheduler started monitoring")
  }
  
  /// Stops listening for notifications.
  func stopMonitoring() {
    guard isActive else { return }
    isActive = false
    
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    
    logger.info("CapEx submission scheduler stopped monitoring")
  }
  
  @objc private func systemDidWake(_ notification: Notification) {
    logger.info("System did wake - checking CapEx submission schedule")
    checkAndSubmit()
  }
  
  @objc private func screenDidUnlock(_ notification: Notification) {
    logger.info("Screen did unlock - checking CapEx submission schedule")
    checkAndSubmit()
  }
  
  /// Checks if the submission should run and executes it if conditions are met.
  private func checkAndSubmit() {
    guard let appState = appState else {
      logger.warning("AppState not available for CapEx submission check")
      return
    }
    
    let submitConfig = appState.capExSubmitConfig
    let capExConfig = appState.capExConfig
    
    guard submissionService.shouldRunNow(submitConfig: submitConfig) else {
      logger.debug("CapEx submission conditions not met")
      return
    }
    
    logger.info("CapEx submission conditions met - executing script")
    
    Task {
      do {
        let output = try await submissionService.executeScript(
          template: submitConfig.scriptTemplate,
          config: capExConfig
        )
        logger.info("CapEx submission succeeded: \(output.prefix(100), privacy: .private)")
        
        // Update last submitted tracking
        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.yearForWeekOfYear, from: now)
        let currentWeek = calendar.component(.weekOfYear, from: now)
        let weekKey = currentYear * 100 + currentWeek
        
        appState.capExSubmitConfig.lastSubmittedAt = now
        appState.capExSubmitConfig.lastSubmittedWeek = weekKey
        
      } catch {
        logger.error("CapEx submission failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
  
  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
  }
}
