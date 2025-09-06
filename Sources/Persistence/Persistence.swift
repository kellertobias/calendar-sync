import Foundation
import SwiftData

/// Wraps SwiftData model container and provides simple load/save helpers.
@MainActor
final class Persistence: ObservableObject {
  let container: ModelContainer

  init() {
    let schema = Schema([
      SDSyncConfig.self,
      SDFilterRule.self,
      SDTimeWindow.self,
      SDEventMapping.self,
      SDSyncRunLog.self,
      // Include per-action log rows so LogsView can fetch actions by run id.
      SDSyncActionLog.self,
      SDAppSettings.self,
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    do {
      container = try ModelContainer(for: schema, configurations: [config])
    } catch {
      fatalError("Failed to create ModelContainer: \(error)")
    }
  }
}
