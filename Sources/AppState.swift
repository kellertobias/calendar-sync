import Foundation
import SwiftUI

/// Global app state for UI-only scaffolding.
/// Why: Centralizes observable properties for menu rendering, settings, and sync list prior to wiring persistence and EventKit.
final class AppState: ObservableObject {
  /// Human-readable last run status for the whole app.
  @Published var lastRunStatus: LastRunStatus = LastRunStatus(
    lastSuccessAt: nil, lastFailureAt: nil, lastMessage: nil)

  /// In-memory sync configurations backing the UI.
  /// Note: Starts empty and is populated from persistence on app launch to avoid ghost entries.
  @Published var syncs: [SyncConfigUI] = []

  /// Currently selected sync in the Syncs window (shared across views).
  @Published var selectedSyncId: UUID? = nil

  /// Settings scaffolding
  @Published var defaultHorizonDays: Int = 14
  @Published var intervalSeconds: Int = 900  // 15 min
  @Published var diagnosticsEnabled: Bool = true
  @Published var tasksURL: String = ""

  @Published var capExConfig: CapExConfigUI = CapExConfigUI(
    workingTimeCalendarId: "",
    historyDays: 30,
    showDaily: true,
    rules: []
  )

  /// Available calendars; sourced from EventKit once authorized.
  @Published var availableCalendars: [CalendarOption] = []

  /// Initiates a manual sync run (UI stub).
  func syncNow() {
    // For scaffolding, we update the last run status without performing any real sync.
    lastRunStatus.lastSuccessAt = Date()
    lastRunStatus.lastMessage = "Sync triggered (UI stub)"
  }

  /// Adds a new default sync configuration (UI stub).
  func addSync() {
    let new = SyncConfigUI(
      name: "New Sync",
      sourceCalendarId: "",
      targetCalendarId: "",
      mode: .blocker,
      blockerTitleTemplate: "Busy",
      horizonDaysOverride: nil,
      enabled: false)
    syncs.append(new)
    selectedSyncId = new.id
  }

  /// Deletes a sync configuration by id.
  func deleteSync(id: UUID) {
    syncs.removeAll { $0.id == id }
  }
}
