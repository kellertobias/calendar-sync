import AppKit
import SwiftUI

/// Menu content displayed under the menu bar item.
/// Contains last sync status, a list of configured syncs, creation entry, and Settings.
struct MenuContentView: View {
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var coordinator: SyncCoordinator
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: syncNow) {
        HStack(spacing: 8) {
          // Show lightweight progress UI while a sync is running for better feedback.
          if coordinator.isSyncing {
            ProgressView().scaleEffect(0.7)
          }
          Text(lastSyncText())
          Spacer()
        }
      }

      Divider()

      if appState.syncs.isEmpty {
        Text("No syncs configured")
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
      } else {
        ForEach(appState.syncs) { sync in
          Button(action: { openSyncEditor(sync.id) }) {
            HStack(spacing: 8) {
              Image(systemName: sync.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(sync.enabled ? .green : .secondary)
              VStack(alignment: .leading) {
                Text(sync.name)
                Text(sync.mode == .blocker ? "Blocker-only" : "Full info")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
          }
        }
      }

      Divider()

      Button("Settings…", action: openSettings)
      Divider()
      Button("Quit Calendar Sync", action: quitApp)
    }
    .padding(8)
    .frame(minWidth: 260)
  }
  private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  /// Computes the status line displayed at the top of the menu.
  /// Why: Use the coordinator as the single source of truth so we reflect live updates
  /// (e.g., "Syncing…", success, or failure) without racing an intermediate appState copy.
  private func lastSyncText() -> String {
    if coordinator.isSyncing { return "Syncing… — please wait" }
    let status = coordinator.lastStatus
    if let failure = status.lastFailureAt,
      failure > (status.lastSuccessAt ?? .distantPast)
    {
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .short
      let rel = formatter.localizedString(for: failure, relativeTo: Date())
      return "Last Error: \(rel) — click to Sync Now"
    } else if let last = status.lastSuccessAt {
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .short
      let rel = formatter.localizedString(for: last, relativeTo: Date())
      return "Last Sync: \(rel) — click to Sync Now"
    } else {
      return "Last Sync: never — click to Sync Now"
    }
  }

  /// Opens the app's Settings window.
  /// Why: Some macOS versions or contexts (e.g., `MenuBarExtra`) may not
  /// reliably open the Settings scene by id. We first attempt the official
  /// SwiftUI API, then fall back to the AppKit selector.
  private func openSettings() { openWindow(id: "settings") }

  private func openSyncEditor(_ id: UUID) {
    appState.selectedSyncId = id
    openWindow(id: "syncs")
  }

  /// Triggers a sync for all enabled configs. Status will update via `coordinator.lastStatus`.
  private func syncNow() {
    coordinator.syncNow(
      configs: appState.syncs,
      defaultHorizonDays: appState.defaultHorizonDays,
      diagnosticsEnabled: appState.diagnosticsEnabled
    )
    // Intentionally do not copy status into appState to avoid stale reads; the UI derives
    // directly from `coordinator` for live progress and final timestamps.
  }
}

#Preview {
  MenuContentView()
    .environmentObject(AppState())
}
