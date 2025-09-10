import AppKit
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

        // Data
        Text("Data").font(.headline)
          .padding(.top, 16)
          .padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            Button("Export Data…") { exportDataZip() }
            Button("Import Data…") { importDataZip() }
            Button("Open Backups Folder") { openBackupsFolder() }
          }
          Text(
            "Export creates a timestamped backup folder under Application Support/Backups. Import restores from the most recent backup folder automatically and relaunches the app."
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

  // MARK: - Export / Import

  /// Returns URLs of existing SwiftData store files in Application Support.
  /// Why: We export all present files (`default.store`, `default.store-wal`, `default.store-shm`) to preserve transactional state.
  private func storeFileURLs() -> [URL] {
    let fm = FileManager.default
    guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      return []
    }
    let candidates = ["default.store", "default.store-wal", "default.store-shm"].map {
      appSupport.appendingPathComponent($0)
    }
    return candidates.filter { fm.fileExists(atPath: $0.path) }
  }

  /// Opens an NSSavePanel and writes a ZIP containing the SwiftData store files.
  private func exportDataZip() {
    let logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "ExportImport")
    logger.info("exportDataZip invoked")

    var files = storeFileURLs()

    do {
      // Compute destination inside the app container so sandbox permits writing
      guard
        let appSupport = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first
      else {
        throw NSError(
          domain: "CalendarSync.Export", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Could not locate Application Support directory"])
      }
      let backupsDir = appSupport.appendingPathComponent("Backups", isDirectory: true)
      try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
      let df = DateFormatter()
      df.dateFormat = "yyyyMMdd-HHmmss"
      let destFolder = backupsDir.appendingPathComponent(
        "CalendarSync-Backup-\(df.string(from: Date()))", isDirectory: true)
      try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)

      // If there are no store files, create a small placeholder so export still proceeds.
      if files.isEmpty {
        let placeholder = destFolder.appendingPathComponent("README.txt")
        let msg =
          "No SwiftData store files were present at export time. This backup contains only this note."
        try msg.data(using: .utf8)?.write(to: placeholder)
        files = [placeholder]
        logger.info("No store files found; created placeholder README.txt")
      } else {
        // Copy store files into destination folder
        for src in files {
          let dst = destFolder.appendingPathComponent(src.lastPathComponent)
          if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
          }
          try FileManager.default.copyItem(at: src, to: dst)
        }
      }

      logger.info("Backup created at \(destFolder.path, privacy: .public)")

      // Show success and reveal the folder in Finder
      let alert = NSAlert()
      alert.messageText = "Export Successful"
      alert.informativeText = "Backup folder created at: \(destFolder.path)"
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Reveal in Finder")
      alert.addButton(withTitle: "OK")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting([destFolder])
      }
    } catch {
      logger.error("Error during export: \(error.localizedDescription, privacy: .public)")

      // Show error alert
      let alert = NSAlert()
      alert.messageText = "Export Failed"
      alert.informativeText = "Error: \(error.localizedDescription)"
      alert.alertStyle = .critical
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  /// Opens an NSOpenPanel, unzips the selected archive, and replaces store files.
  /// The app relaunches after a successful import so the new store is loaded.
  private func importDataZip() {
    let logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "ExportImport")
    logger.info("importDataZip invoked (auto-restore latest backup)")

    do {
      let fm = FileManager.default
      guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      else {
        throw NSError(
          domain: "CalendarSync.Import", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Could not locate Application Support directory"])
      }
      let backupsDir = appSupport.appendingPathComponent("Backups", isDirectory: true)
      logger.debug("Backups directory: \(backupsDir.path, privacy: .public)")

      guard fm.fileExists(atPath: backupsDir.path) else {
        throw NSError(
          domain: "CalendarSync.Import", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "No backups directory found. Run Export first."])
      }

      // Find most recent backup folder matching our naming pattern
      let entries = try fm.contentsOfDirectory(
        at: backupsDir, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
      let folders = entries.filter { url in
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue && url.lastPathComponent.hasPrefix("CalendarSync-Backup-")
      }
      guard
        let latest = folders.max(by: { (a, b) -> Bool in
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
          domain: "CalendarSync.Import", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "No backup folders found."])
      }

      logger.info("Restoring from latest backup folder: \(latest.path, privacy: .public)")

      var importedFiles = 0
      for name in ["default.store", "default.store-wal", "default.store-shm"] {
        let src = latest.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { continue }
        let dst = appSupport.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        importedFiles += 1
      }

      if importedFiles == 0 {
        throw NSError(
          domain: "CalendarSync.Import", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Backup folder did not contain any data files."])
      }

      // Success alert
      let alert = NSAlert()
      alert.messageText = "Import Successful"
      alert.informativeText =
        "Restored from: \(latest.lastPathComponent). The app will now restart."
      alert.alertStyle = .informational
      alert.addButton(withTitle: "OK")
      alert.runModal()

      logger.info("Scheduling delayed relaunch after successful import")
      self.beginDelayedRelaunch()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Import Failed"
      alert.informativeText = "Error: \(error.localizedDescription)"
      alert.alertStyle = .critical
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

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
