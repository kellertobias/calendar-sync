import AppKit
import EventKit
import OSLog
import ServiceManagement
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
  @Environment(\.modelContext) private var context
  @State private var isRestarting: Bool = false

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
            Text(isRestarting ? "Restarting, please wait…" : auth.statusDescription)
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
              Button("Relaunch App") { beginDelayedRelaunch() }
                .help("Relaunch to ensure entitlements are applied if access doesn't update.")
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

          // Reminder Access Section
          HStack(alignment: .firstTextBaseline) {
            Text("Reminder Access").frame(width: labelWidth, alignment: .leading)
            Text(auth.reminderStatusDescription)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, 4)
          HStack(spacing: 12) {
            Button("Request Reminder Access") {
              auth.requestReminderAccess()
            }
            if !auth.hasReminderAccess {
              Text("Required for task synchronization")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
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
          Button("Sync Now") { performManualSyncNow() }
        }
        .padding(.vertical, 4)

        Divider()

        // Settings Import/Export
        Text("Settings").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            Button("Export Settings…") { exportSettingsJSON() }
            Button("Import Settings…") { importSettingsJSON() }
            Button("Open Backups Folder") { openBackupsFolder() }
          }
          Text(
            "Exports settings to a timestamped JSON in Application Support/Backups. Import replaces current sync configurations from the most recent settings JSON."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        // Tasks URL
        Text("Tasks Integration").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Text("Tasks URL").frame(width: labelWidth, alignment: .leading)
            TextField("https://example.com/tasks", text: $appState.tasksURL)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, 4)
          Text(
            "If this field is filled out, we will fetch the tasks scheduled for the sync time horizon as POST request to this URL"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

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
            "Removes all items in active target calendars containing the CalendarSync tag."
          )
          .padding(.vertical, 4)

          // Clear only the internal mapping store without touching calendar events.
          Button(role: .destructive) {
            confirmAndClearEventMappings()
          } label: {
            Label {
              Text("Clear Internal Synced-State")
                .foregroundStyle(.primary)
            } icon: {
              Image(systemName: "trash.slash")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.red)
            }
          }
          .help(
            "Deletes the internal mapping database (SDEventMapping) but does not modify any calendar events."
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

  /// Removes all items managed by CalendarSync across all ACTIVE sync target calendars.
  /// Behavior:
  /// - Resolves unique target calendars from enabled syncs via EventKit.
  /// - Prompts the user with a confirmation dialog listing the calendar names.
  /// - On confirmation, invokes a purge that enumerates calendars directly and deletes events
  ///   whose description contains the branding line "Tobisk Calendar Sync".
  /// - Logs all deletions as "delete" actions in the run logs.
  private func removeAllSyncedItems() {
    // Gather unique target calendar identifiers from enabled syncs.
    let enabledSyncs = appState.syncs.filter { $0.enabled }
    let targetIds = Array(Set(enabledSyncs.map { $0.targetCalendarId }))

    // Resolve human-readable calendar titles directly from EventKit (no internal store).
    let store = EKEventStore()
    let resolvedTitles: [String] = targetIds.map { id in
      if let cal = store.calendar(withIdentifier: id) {
        return cal.title
      } else {
        return "<missing> (\(id))"
      }
    }

    // Construct and present a confirmation dialog that lists target calendars.
    let alert = NSAlert()
    alert.messageText = "Purge Selected Calendars?"
    let list = resolvedTitles.isEmpty ? "(none)" : resolvedTitles.joined(separator: "\n• ")
    alert.informativeText =
      "This will permanently delete all events containing ‘Tobisk Calendar Sync’ in these calendars:\n• \(list)\n\nThis cannot be undone."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Purge")
    alert.addButton(withTitle: "Cancel")

    print("Alert: \(alert)")
    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else {
      print("Response Cancel: \(response)")
      return
    }

    print("Response: \(response)")

    // Invoke a dedicated purge that enumerates target calendars directly via EventKit.
    coordinator.purgeAll(configs: appState.syncs, diagnosticsEnabled: appState.diagnosticsEnabled)
  }

  /// Triggers an immediate sync using the current app settings and configurations.
  /// - Note: Uses `SyncCoordinator.syncNow` so progress and status are reflected via `lastStatus`.
  private func performManualSyncNow() {
    coordinator.syncNow(
      configs: appState.syncs,
      defaultHorizonDays: appState.defaultHorizonDays,
      diagnosticsEnabled: appState.diagnosticsEnabled,
      tasksURL: appState.tasksURL.isEmpty ? nil : appState.tasksURL
    )
  }

  /// Prompts for confirmation and then clears all `SDEventMapping` rows from the SwiftData store.
  /// Why: Allows resetting internal knowledge of which items were synced, without touching calendars.
  private func confirmAndClearEventMappings() {
    let alert = NSAlert()
    alert.messageText = "Clear Internal Synced-State?"
    alert.informativeText =
      "This deletes the internal mapping records that track which events have been synced. Calendar items will not be changed. This cannot be undone."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    do {
      // Fetch all mappings in a single descriptor and delete them.
      let fetch = FetchDescriptor<SDEventMapping>()
      let all = try context.fetch(fetch)
      for row in all { context.delete(row) }
      try context.save()

      let ok = NSAlert()
      ok.messageText = "Cleared"
      ok.informativeText = "Internal synced-state (mappings) has been cleared."
      ok.alertStyle = .informational
      ok.addButton(withTitle: "OK")
      ok.runModal()
    } catch {
      let fail = NSAlert()
      fail.messageText = "Failed to Clear"
      fail.informativeText = "Error: \(error.localizedDescription)"
      fail.alertStyle = .critical
      fail.addButton(withTitle: "OK")
      fail.runModal()
    }
  }

  /// Exports only the sync configuration settings (and nested filter/time window rules) as JSON.
  /// - Note: This intentionally excludes internal synced-state like `SDEventMapping` and all logs.
  private func exportSettingsJSON() {
    let logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "ExportImport")
    logger.info("exportSettingsJSON invoked")

    do {
      // Fetch the latest saved sync configurations with relationships.
      let fetch = FetchDescriptor<SDSyncConfig>()
      let models = try context.fetch(fetch)

      // Transform into a stable, Codable export representation.
      let syncs: [SyncExport] = models.map { m in
        let filters = m.filters.map {
          FilterExport(
            id: $0.id, type: $0.typeRaw, pattern: $0.pattern, caseSensitive: $0.caseSensitive)
        }
        let windows = m.timeWindows.map {
          TimeWindowExport(
            id: $0.id,
            weekday: $0.weekdayRaw,
            startHour: $0.startHour,
            startMinute: $0.startMinute,
            endHour: $0.endHour,
            endMinute: $0.endMinute
          )
        }
        return SyncExport(
          id: m.id,
          name: m.name,
          sourceCalendarId: m.sourceCalendarId,
          targetCalendarId: m.targetCalendarId,
          mode: m.modeRaw,
          blockerTitleTemplate: m.blockerTitleTemplate,
          horizonDaysOverride: m.horizonDaysOverride,
          enabled: m.enabled,
          createdAt: m.createdAt,
          updatedAt: m.updatedAt,
          filters: filters,
          timeWindows: windows
        )
      }

      let payload = SyncSettingsExport(version: 1, generatedAt: Date(), syncs: syncs)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(payload)

      // Write into the Backups folder inside Application Support with a timestamped filename.
      let fm = FileManager.default
      guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      else {
        throw NSError(
          domain: "CalendarSync.Export", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "Could not locate Application Support directory"])
      }
      let backupsDir = appSupport.appendingPathComponent("Backups", isDirectory: true)
      if !fm.fileExists(atPath: backupsDir.path) {
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
      }
      let df = DateFormatter()
      df.dateFormat = "yyyyMMdd-HHmmss"
      let fileURL = backupsDir.appendingPathComponent(
        "CalendarSync-Settings-\(df.string(from: Date())).json")
      try data.write(to: fileURL, options: [.atomic])

      let alert = NSAlert()
      alert.messageText = "Export Successful"
      alert.informativeText = "Settings exported to: \(fileURL.path)"
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Reveal in Finder")
      alert.addButton(withTitle: "OK")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
      }
    } catch {
      let alert = NSAlert()
      alert.messageText = "Export Failed"
      alert.informativeText = "Error: \(error.localizedDescription)"
      alert.alertStyle = .critical
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  /// Imports settings from the most recent settings JSON file in the Backups folder.
  /// Prompts for confirmation, then replaces all existing sync configurations.
  private func importSettingsJSON() {
    let logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "ExportImport")
    logger.info("importSettingsJSON invoked (auto-restore latest settings JSON)")

    do {
      let fm = FileManager.default
      guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      else {
        throw NSError(
          domain: "CalendarSync.Import", code: 11,
          userInfo: [NSLocalizedDescriptionKey: "Could not locate Application Support directory"])
      }
      let backupsDir = appSupport.appendingPathComponent("Backups", isDirectory: true)
      guard fm.fileExists(atPath: backupsDir.path) else {
        throw NSError(
          domain: "CalendarSync.Import", code: 12,
          userInfo: [NSLocalizedDescriptionKey: "No Backups directory found. Run Export first."])
      }

      // Find most recent settings JSON matching our naming scheme.
      let entries = try fm.contentsOfDirectory(
        at: backupsDir, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
      let jsons = entries.filter { url in
        url.lastPathComponent.hasPrefix("CalendarSync-Settings-")
          && url.pathExtension.lowercased() == "json"
      }
      guard
        let latest = jsons.max(by: { (a, b) -> Bool in
          let aDate =
            (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
          let bDate =
            (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
          return aDate < bDate
        })
      else {
        throw NSError(
          domain: "CalendarSync.Import", code: 13,
          userInfo: [NSLocalizedDescriptionKey: "No settings JSON files found in Backups."])
      }

      let data = try Data(contentsOf: latest)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let payload = try decoder.decode(SyncSettingsExport.self, from: data)

      // Confirm replacement of current settings.
      let confirm = NSAlert()
      confirm.messageText = "Replace Current Settings?"
      confirm.informativeText =
        "This will replace all current sync configurations with those from \(latest.lastPathComponent). This cannot be undone."
      confirm.alertStyle = .warning
      confirm.addButton(withTitle: "Replace")
      confirm.addButton(withTitle: "Cancel")
      guard confirm.runModal() == .alertFirstButtonReturn else { return }

      // Delete all existing configs (cascade removes rules) and insert from JSON.
      let existing = try context.fetch(FetchDescriptor<SDSyncConfig>())
      for m in existing { context.delete(m) }

      for s in payload.syncs {
        let filters = s.filters.map { f in
          SDFilterRule(
            id: f.id, typeRaw: f.type, pattern: f.pattern, caseSensitive: f.caseSensitive)
        }
        let windows = s.timeWindows.map { w in
          SDTimeWindow(
            id: w.id,
            weekdayRaw: w.weekday,
            startHour: w.startHour,
            startMinute: w.startMinute,
            endHour: w.endHour,
            endMinute: w.endMinute
          )
        }
        let model = SDSyncConfig(
          id: s.id,
          name: s.name,
          sourceCalendarId: s.sourceCalendarId,
          targetCalendarId: s.targetCalendarId,
          modeRaw: s.mode,
          blockerTitleTemplate: s.blockerTitleTemplate,
          horizonDaysOverride: s.horizonDaysOverride,
          enabled: s.enabled,
          createdAt: s.createdAt,
          updatedAt: s.updatedAt,
          filters: filters,
          timeWindows: windows
        )
        context.insert(model)
      }

      try context.save()

      // Refresh in-memory UI state to reflect imported models immediately.
      let refreshed = try context.fetch(FetchDescriptor<SDSyncConfig>())
      appState.syncs = refreshed.map { $0.toUI() }

      let done = NSAlert()
      done.messageText = "Import Successful"
      done.informativeText = "Imported settings from: \(latest.lastPathComponent)"
      done.alertStyle = .informational
      done.addButton(withTitle: "OK")
      done.runModal()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Import Failed"
      alert.informativeText = "Error: \(error.localizedDescription)"
      alert.alertStyle = .critical
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  /// Top-level export payload for settings-only exports.
  /// This excludes any internal state such as `SDEventMapping` and sync logs.
  private struct SyncSettingsExport: Codable {
    let version: Int
    let generatedAt: Date
    let syncs: [SyncExport]
  }

  /// Export model for a single sync configuration.
  private struct SyncExport: Codable {
    let id: UUID
    let name: String
    let sourceCalendarId: String
    let targetCalendarId: String
    let mode: String
    let blockerTitleTemplate: String?
    let horizonDaysOverride: Int?
    let enabled: Bool
    let createdAt: Date
    let updatedAt: Date
    let filters: [FilterExport]
    let timeWindows: [TimeWindowExport]
  }

  /// Export model for a filter rule within a sync configuration.
  private struct FilterExport: Codable {
    let id: UUID
    let type: String
    let pattern: String
    let caseSensitive: Bool
  }

  /// Export model for a time window within a sync configuration.
  private struct TimeWindowExport: Codable {
    let id: UUID
    let weekday: String
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int
  }

  /// Removes all configured syncs from persistence while keeping calendar items.
  private func removeAllSyncs() {
    appState.syncs.removeAll()
  }

  /// Relaunches the current app bundle.
  /// Why: Ensures a fresh process after operations like permission changes or data import.
  private func relaunchApp() {
    let logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "Relaunch")

    let bundleURL = Bundle.main.bundleURL
    let bundlePath = bundleURL.path

    // Most reliable for LSUIElement/menu bar apps: spawn a detached helper shell
    // that waits until we exit, then re-opens a new instance. This avoids LS
    // suppressing a new instance while the old one is still alive.
    do {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      // Increase delay to allow LaunchServices to fully release the old instance.
      let cmd = "sleep 1.5; /usr/bin/open -n \"\(bundlePath)\""
      process.arguments = ["-c", cmd]
      process.standardOutput = nil
      process.standardError = nil
      try process.run()
      logger.info("Scheduled relaunch via /bin/sh helper with 1.5s delay")
      // Terminate immediately so the helper can bring up the new instance
      NSApplication.shared.terminate(nil)
      return
    } catch {
      logger.error(
        "Helper relaunch failed: \(error.localizedDescription, privacy: .public). Falling back to NSWorkspace"
      )
    }

    // Fallback: modern API (may be unreliable if called before termination)
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        NSApplication.shared.terminate(nil)
      }
    }
  }

  // MARK: - Export / Import (Settings only)

  // Data import/export removed: app now supports settings JSON import/export only.

  /// Opens the Application Support/Backups directory in Finder, creating it if needed.
  /// Why: Allows users to copy backup folders in/out manually, which import/export will use.
  private func openBackupsFolder() {
    let logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "ExportImport")
    do {
      let fm = FileManager.default
      guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      else {
        throw NSError(
          domain: "CalendarSync.Backups", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Could not locate Application Support directory"])
      }
      let backupsDir = appSupport.appendingPathComponent("Backups", isDirectory: true)
      if !fm.fileExists(atPath: backupsDir.path) {
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
      }
      logger.info("Opening Backups folder: \(backupsDir.path, privacy: .public)")
      NSWorkspace.shared.activateFileViewerSelecting([backupsDir])
    } catch {
      let alert = NSAlert()
      alert.messageText = "Couldn’t Open Backups Folder"
      alert.informativeText = "Error: \(error.localizedDescription)"
      alert.alertStyle = .critical
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  /// Schedules a short visible delay before relaunching, showing a status hint.
  /// Why: Gives LaunchServices time to release the current instance and communicates progress.
  private func beginDelayedRelaunch(delaySeconds: TimeInterval = 1.0) {
    isRestarting = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
      self.relaunchApp()
    }
  }
}

#Preview {
  SettingsView().environmentObject(AppState())
}
