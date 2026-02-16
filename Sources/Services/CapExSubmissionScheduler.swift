import Foundation
import OSLog
import AppKit
import SwiftData

/// Scheduler that monitors system wake and unlock events to trigger CapEx script submission
/// when the configured schedule conditions are met.
@MainActor
final class CapExSubmissionScheduler: ObservableObject {
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "CapExScheduler")
  private let submissionService = CapExSubmissionService()
  private weak var appState: AppState?
  private var modelContext: ModelContext?
  private var timer: Timer?
  
  /// Whether the scheduler is actively monitoring for wake/unlock events.
  @Published var isActive: Bool = false
  
  init() {}
  
  /// Configures the scheduler with required dependencies and starts monitoring.
  func configure(appState: AppState, modelContext: ModelContext) {
    self.appState = appState
    self.modelContext = modelContext
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

    // Timer for checking every minute
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      self?.checkAndSubmit()
    }
    
    // Initial check
    checkAndSubmit()
    
    logger.info("CapEx submission scheduler started monitoring")
  }
  
  /// Stops listening for notifications.
  func stopMonitoring() {
    guard isActive else { return }
    isActive = false
    
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    timer?.invalidate()
    timer = nil
    
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
        guard let context = self.modelContext else {
             logger.error("ModelContext not available for submission")
             return
        }
        
        let identifier = CapExSubmissionService.weekIdentifier(for: Date())
        
        try await submissionService.submit(
          template: submitConfig.scriptTemplate,
          config: capExConfig,
          periodIdentifier: identifier,
          context: context
        )
        logger.info("CapEx submission succeeded")
        
        // Update in-memory state for immediate UI feedback (though Query will update too)
        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.yearForWeekOfYear, from: now)
        let currentWeek = calendar.component(.weekOfYear, from: now)
        let weekKey = currentYear * 100 + currentWeek
        
        appState.capExSubmitConfig.lastSubmittedAt = now
        appState.capExSubmitConfig.lastSubmittedWeek = weekKey
        
      } catch {
        logger.error("CapEx submission failed: \(error.localizedDescription)")
      }
    }
  }
  
  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
  }
}
