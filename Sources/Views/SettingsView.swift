import AppKit
import ServiceManagement
import SwiftData
import SwiftUI

enum SettingsSidebarItem: Hashable, Identifiable {
  case sync(UUID)
  case settings
  var id: String {
    switch self {
    case .sync(let id): return "sync-\(id.uuidString)"
    case .settings: return "settings"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var auth: EventKitAuth
  @EnvironmentObject var calendars: EventKitCalendars
  @State private var selection: SettingsSidebarItem? = .settings
  @EnvironmentObject var coordinator: SyncCoordinator
  @Environment(\.modelContext) private var context
  @Query(sort: \SDSyncConfig.name) private var storedSyncs: [SDSyncConfig]

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Spacer()
          Button {
            addSync()
          } label: {
            Label("New Sync", systemImage: "plus")
          }
          Button(role: .destructive) {
            deleteSelectedSync()
          } label: {
            Label("Delete", systemImage: "trash")
          }
          Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        Divider()
        List(selection: $selection) {
          Section("Syncs") {
            if appState.syncs.isEmpty {
              // Empty-state hint in the sidebar when there are no syncs.
              VStack(alignment: .leading, spacing: 4) {
                Text("No syncs configured")
                  .foregroundStyle(.secondary)
                Text("Click ‘New Sync’ above to create your first sync.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else {
              ForEach(appState.syncs) { sync in
                NavigationLink(value: SettingsSidebarItem.sync(sync.id)) {
                  HStack {
                    VStack(alignment: .leading) {
                      Text(sync.name)
                      Text(sync.mode == .blocker ? "Blocker-only" : "Full info")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: binding(for: sync).enabled)
                      .labelsHidden()
                  }
                }
                .contextMenu {
                  Button("Delete", role: .destructive) { appState.deleteSync(id: sync.id) }
                }
              }
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          VStack {
            Button {
              selection = .settings
            } label: {
              Label("Settings", systemImage: "gearshape")
            }
            .frame(maxWidth: .infinity, alignment: .center)
          }
          .padding(.horizontal)
          .padding(.vertical, 8)
          .background(.bar)
        }
        .navigationSplitViewColumnWidth(340)
      }
    } detail: {
      switch selection {
      case .sync(let id):
        if let sync = appState.syncs.first(where: { $0.id == id }) {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              SyncEditorView(sync: binding(for: sync), onRequestSettings: { selection = .settings })
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          ContentUnavailableView("Select a Sync", systemImage: "calendar")
        }
      case .settings, .none:
        SettingsDetail()
      }
    }
    .onAppear {
      // Ensure we show the latest permissions status when Settings appears
      auth.refreshStatus()
      calendars.reload(authorized: auth.hasReadAccess)
      appState.availableCalendars = calendars.calendars
      // If syncs are empty but we have stored models, load them to avoid ghost defaults.
      if appState.syncs.isEmpty && !storedSyncs.isEmpty {
        appState.syncs = storedSyncs.map { $0.toUI() }
      }
    }
    // Persist changes to syncs even when editing from Settings view.
    .onChange(of: appState.syncs) { _, newValue in
      let existingById = Dictionary(uniqueKeysWithValues: storedSyncs.map { ($0.id, $0) })
      var seen: Set<UUID> = []
      for ui in newValue {
        seen.insert(ui.id)
        if let existing = existingById[ui.id] {
          existing.name = ui.name
          existing.sourceCalendarId = ui.sourceCalendarId
          existing.targetCalendarId = ui.targetCalendarId
          existing.modeRaw = ui.mode.rawValue
          existing.blockerTitleTemplate = ui.blockerTitleTemplate
          existing.horizonDaysOverride = ui.horizonDaysOverride
          existing.enabled = ui.enabled
          existing.updatedAt = Date()
          existing.filters = ui.filters.map {
            SDFilterRule(
              id: $0.id, typeRaw: $0.type.rawValue, pattern: $0.pattern,
              caseSensitive: $0.caseSensitive)
          }
          existing.timeWindows = ui.timeWindows.map {
            SDTimeWindow(
              id: $0.id, weekdayRaw: $0.weekday.rawValue, startHour: $0.start.hour,
              startMinute: $0.start.minute, endHour: $0.end.hour, endMinute: $0.end.minute)
          }
        } else {
          let model = SDSyncConfig.fromUI(ui)
          context.insert(model)
        }
      }
      for model in storedSyncs where !seen.contains(model.id) {
        context.delete(model)
      }
      try? context.save()
    }
  }

  private func addSync() {
    appState.addSync()
    if let last = appState.syncs.last { selection = .sync(last.id) }
  }
  private func deleteSelectedSync() {
    if case let .sync(id)? = selection {
      appState.deleteSync(id: id)
      selection = .settings
    }
  }

  private func binding(for sync: SyncConfigUI) -> Binding<SyncConfigUI> {
    guard let idx = appState.syncs.firstIndex(of: sync) else { return .constant(sync) }
    return $appState.syncs[idx]
  }
}

private struct SettingsDetail: View {
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var auth: EventKitAuth
  @EnvironmentObject var calendars: EventKitCalendars
  @Environment(\.openWindow) private var openWindow
  @EnvironmentObject var coordinator: SyncCoordinator

  var body: some View {
    ScrollView {
      let labelWidth: CGFloat = 180
      VStack(alignment: .leading, spacing: 24) {
        // Permissions
        Text("Permissions").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            Text("Calendar Access").frame(width: labelWidth, alignment: .leading)
            Text(auth.statusDescription)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, 4)
          HStack(spacing: 12) {
            Button("Request Full Access") {
              auth.requestFullAccess {
                calendars.reload(authorized: auth.hasReadAccess)
                appState.availableCalendars = calendars.calendars
              }
            }
            Button("Open System Settings") { auth.openSystemSettings() }
            if !auth.hasReadAccess {
              Button("Relaunch App") { relaunchApp() }
                .help("Relaunch to ensure entitlements are applied if access doesn’t update.")
            }
          }
          .padding(.vertical, 4)
          if !auth.hasReadAccess {
            VStack(alignment: .leading, spacing: 4) {
              Text("Full access is required to plan syncs and select calendars.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              Text("Use the buttons above to request access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Divider()

        // Sync Interval
        Text("Sync Interval").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        HStack(alignment: .firstTextBaseline) {
          Text("Interval").frame(width: labelWidth, alignment: .leading)
          Picker("Interval", selection: $appState.intervalSeconds) {
            Text("5 min").tag(300)
            Text("15 min").tag(900)
            Text("30 min").tag(1800)
            Text("1 hour").tag(3600)
          }
          .labelsHidden()
          .frame(width: 180, alignment: .leading)
          Spacer()
        }
        .padding(.vertical, 4)

        Divider()

        // Defaults
        Text("Defaults").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Text("Default Horizon").frame(width: labelWidth, alignment: .leading)
            Stepper(value: $appState.defaultHorizonDays, in: 1...365) {
              Text("\(appState.defaultHorizonDays) days")
            }
            .frame(width: 220, alignment: .leading)
            Spacer()
          }
          .padding(.vertical, 4)
          Text(
            "How far into the future to look for events when planning syncs if a sync doesn’t specify its own horizon."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        // Diagnostics
        Text("Diagnostics").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 12) {
          Toggle("Enable Diagnostics", isOn: $appState.diagnosticsEnabled)
            .padding(.vertical, 4)
          Button("Open Logs") { openWindow(id: "logs") }
            .padding(.vertical, 4)
        }

        Divider()

        // Launch
        Text("Launch").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        Toggle(
          "Run at Login",
          isOn: Binding(
            get: { RunAtLogin.isEnabled() },
            set: { newValue in
              do { try RunAtLogin.setEnabled(newValue) } catch { /* best-effort */  }
            }
          )
        )
        .padding(.vertical, 4)

        Divider()

        // Danger Zone
        Text("Danger Zone").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 12) {
          // Use a custom Label so only the icon appears red while text remains primary.
          Button(role: .destructive) {
            removeAllSyncedItems()
          } label: {
            Label {
              Text("Remove all Synced Items")
                .foregroundStyle(.primary)
            } icon: {
              Image(systemName: "trash")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.red)
            }
          }
          .help(
            "Removes all calendar items created by CalendarSync (identified via mapping + tag)."
          )
          .padding(.vertical, 4)

          // Same styling for this destructive action: red icon, primary text.
          Button(role: .destructive) {
            removeAllSyncs()
          } label: {
            Label {
              Text("Remove all Syncs")
                .foregroundStyle(.primary)
            } icon: {
              Image(systemName: "trash")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.red)
            }
          }
          .help("Deletes all configured syncs but keeps existing calendar items.")
          .padding(.vertical, 4)
        }
      }
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.top, 16)
      .padding(.bottom, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// Removes all items we created (identified via mapping + tag) across all configs.
  private func removeAllSyncedItems() {
    // Invoke a dedicated purge that enumerates target calendars and removes items
    // carrying our marker for each configured tuple, independent of horizon.
    coordinator.purgeAll(configs: appState.syncs, diagnosticsEnabled: appState.diagnosticsEnabled)
  }

  /// Removes all configured syncs from persistence while keeping calendar items.
  private func removeAllSyncs() {
    appState.syncs.removeAll()
  }

  /// Relaunches the current app bundle.
  /// Why: As a fallback for cases where macOS permission state only updates on a new process.
  private func relaunchApp() {
    guard
      let bundlePath = Bundle.main.bundlePath.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "file://\(bundlePath)")
    else { return }
    let config = NSWorkspace.OpenConfiguration()
    // Launch new instance, then terminate current one once the new instance starts.
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
      NSApplication.shared.terminate(nil)
    }
  }
}

#Preview {
  SettingsView().environmentObject(AppState())
}
