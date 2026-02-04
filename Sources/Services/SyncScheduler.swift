import Foundation
import SwiftUI

/// Periodically triggers sync runs while the app is active.
/// Adds basic exponential backoff on failures and small random jitter between runs to avoid thundering herds.
@MainActor
final class SyncScheduler: ObservableObject {
  private var timer: Timer?
  private let coordinator: SyncCoordinator
  private let appState: AppState

  // Backoff state
  private var failureCount: Int = 0

  init(coordinator: SyncCoordinator, appState: AppState) {
    self.coordinator = coordinator
    self.appState = appState
  }

  /// Starts periodic scheduling. Cancels any existing timer.
  func start() {
    stop()
    scheduleNext(after: 0)
  }

  /// Stops the scheduler timer.
  func stop() {
    timer?.invalidate()
    timer = nil
    nextRunAt = nil
  }

  @Published var nextRunAt: Date?
  
  /// Schedules the next run with jitter and optional delay.
  private func scheduleNext(after initialDelaySeconds: TimeInterval) {
    guard appState.intervalSeconds > 0 else {
      nextRunAt = nil
      return
    }
    // Jitter: +/- 10% of the base interval
    let base = TimeInterval(appState.intervalSeconds)
    let jitterRange = base * 0.1
    let jitter = Double.random(in: -jitterRange...jitterRange)
    let delay = max(1, initialDelaySeconds + base + jitter)
    let nextDate = Date().addingTimeInterval(delay)
    nextRunAt = nextDate
    
    timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.runOnce()
      }
    }
  }

  /// Executes a single sync cycle and reschedules with backoff on failure.
  private func runOnce() {
    coordinator.syncNow(
      configs: appState.syncs, defaultHorizonDays: appState.defaultHorizonDays,
      diagnosticsEnabled: appState.diagnosticsEnabled,
      tasksURL: appState.tasksURL.isEmpty ? nil : appState.tasksURL)

    // Heuristic: if last run message indicates failure, increase backoff
    let didFail =
      coordinator.lastStatus.lastFailureAt != nil
      && (coordinator.lastStatus.lastSuccessAt == nil
        || (coordinator.lastStatus.lastFailureAt ?? Date())
          > (coordinator.lastStatus.lastSuccessAt ?? .distantPast))
    if didFail {
      failureCount = min(failureCount + 1, 5)
    } else {
      failureCount = 0
    }

    // Exponential backoff: 2^n minutes capped at 30 minutes, applied as extra delay
    let extraDelay: TimeInterval
    if failureCount > 0 {
      let minutes = min(pow(2.0, Double(failureCount)), 30.0)
      extraDelay = minutes * 60.0
    } else {
      extraDelay = 0
    }

    scheduleNext(after: extraDelay)
  }
}
