import AppKit
import SwiftData
import SwiftUI

/// The main application entry using SwiftUI and MenuBarExtra.
///
/// Why: We use `MenuBarExtra` to provide a lightweight menu bar UI that keeps
/// the app out of the Dock while offering quick access to sync controls.
/// How: The app defines a menu scene and a Settings window, and creates
/// additional windows for managing sync configurations.
@main
struct CalendarSyncApp: App {
  /// Tracks scene lifecycle to refresh permissions when app becomes active again.
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var appState = AppState()
  @StateObject private var eventKitAuth = EventKitAuth()
  @StateObject private var calendars = EventKitCalendars()
  @StateObject private var persistence = Persistence()
  @StateObject private var coordinatorHolder = CoordinatorHolder()
  @StateObject private var schedulerHolder = SchedulerHolder()

  init() {
    // Terminate earlier running versions of this app
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let bundleID = Bundle.main.bundleIdentifier
    if let bundleID = bundleID {
      let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      for app in runningApps {
        if app.processIdentifier != currentPID {
          app.terminate()
        }
      }
    }
  }

  var body: some Scene {
    // Menu bar entry point with primary controls
    MenuBarExtra(content: {
      MenuContentView()
        .environmentObject(appState)
        .environmentObject(eventKitAuth)
        .environmentObject(calendars)
        .modelContainer(persistence.container)
        .environmentObject(
          coordinatorHolder.coordinator(modelContext: persistence.container.mainContext)
        )
        // Inject the scheduler so the menu can show "next sync" time
        .environmentObject(
          schedulerHolder.scheduler(
            coordinator: coordinatorHolder.coordinator(
              modelContext: persistence.container.mainContext), appState: appState
          )
        )
        .task {
          // Ensure syncs and settings are loaded even if only the menu is opened.
          await loadSyncsFromPersistenceIfNeeded()
          await loadAppSettingsFromPersistenceIfNeeded()
          calendars.reload(authorized: eventKitAuth.hasReadAccess)
          appState.availableCalendars = calendars.calendars

          let hasEnabled = appState.syncs.contains { $0.enabled }
          if !hasEnabled {
            // Bring app to foreground and open Settings (macOS Settings or legacy Preferences)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
              NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
              NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
          }
        }
    }, label: {
      // Dynamic label that shows "Syncing" state
      MenuBarLabel(coordinator: coordinatorHolder.coordinator(modelContext: persistence.container.mainContext))
    })

    // Settings window for permissions and intervals (dedicated id)
    WindowGroup("Settings", id: "settings") {
      SettingsView()
        .environmentObject(appState)
        .environmentObject(eventKitAuth)
        .environmentObject(calendars)
        .modelContainer(persistence.container)
        .environmentObject(
          coordinatorHolder.coordinator(modelContext: persistence.container.mainContext)
        )
        .task {
          calendars.reload(authorized: eventKitAuth.hasReadAccess)
          appState.availableCalendars = calendars.calendars
          // Load syncs and settings from SwiftData only once on first launch into this window.
          await loadSyncsFromPersistenceIfNeeded()
          await loadAppSettingsFromPersistenceIfNeeded()
          schedulerHolder.scheduler(
            coordinator: coordinatorHolder.coordinator(
              modelContext: persistence.container.mainContext), appState: appState
          ).start()
        }
    }

    // Window for managing sync tuples (UI-first stub)
    WindowGroup("Syncs", id: "syncs") {
      SyncListView()
        .environmentObject(appState)
        .environmentObject(eventKitAuth)
        .environmentObject(calendars)
        .modelContainer(persistence.container)
        .environmentObject(
          coordinatorHolder.coordinator(modelContext: persistence.container.mainContext)
        )
        .task {
          calendars.reload(authorized: eventKitAuth.hasReadAccess)
          appState.availableCalendars = calendars.calendars
          await loadSyncsFromPersistenceIfNeeded()
          await loadAppSettingsFromPersistenceIfNeeded()
          schedulerHolder.scheduler(
            coordinator: coordinatorHolder.coordinator(
              modelContext: persistence.container.mainContext), appState: appState
          ).start()
        }
    }
    .defaultSize(width: 680, height: 520)
    .onChange(of: appState.intervalSeconds) { _, _ in
      schedulerHolder.scheduler(
        coordinator: coordinatorHolder.coordinator(modelContext: persistence.container.mainContext),
        appState: appState
      ).start()
      saveAppSettings()
    }
    .onChange(of: appState.defaultHorizonDays) { _, _ in
      saveAppSettings()
    }
    .onChange(of: appState.diagnosticsEnabled) { _, _ in
      saveAppSettings()
    }
    .onChange(of: appState.tasksURL) { _, _ in
      saveAppSettings()
    }
    .onChange(of: eventKitAuth.status) { _, _ in
      calendars.reload(authorized: eventKitAuth.hasReadAccess)
      appState.availableCalendars = calendars.calendars
    }
    // Refresh permissions when the app returns to the foreground so status changes are picked up
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      eventKitAuth.refreshStatus()
      calendars.reload(authorized: eventKitAuth.hasReadAccess)
      appState.availableCalendars = calendars.calendars
    }

    // CapEx Report Window
    WindowGroup("Activatable Hours", id: "capex") {
        CapExReportView()
            .environmentObject(appState)
            .environmentObject(calendars)
            .task {
                calendars.reload(authorized: eventKitAuth.hasReadAccess)
                appState.availableCalendars = calendars.calendars
                await loadSyncsFromPersistenceIfNeeded()
                await loadAppSettingsFromPersistenceIfNeeded()
            }
    }

    // Logs window
    WindowGroup("Logs", id: "logs") {
      LogsView()
        .environmentObject(appState)
        // Provide model container so LogsView's SwiftData query can fetch persisted logs.
        .modelContainer(persistence.container)
    }
  }

  /// Loads stored syncs into `appState.syncs` once to avoid ghost defaults.
  @MainActor
  private func loadSyncsFromPersistenceIfNeeded() async {
    if !appState.syncs.isEmpty { return }
    let context = persistence.container.mainContext
    do {
      let descriptor = FetchDescriptor<SDSyncConfig>(sortBy: [SortDescriptor(\.name)])
      let stored = try context.fetch(descriptor)
      if !stored.isEmpty {
        appState.syncs = stored.map { $0.toUI() }
      }
    } catch {
      // Best-effort; leave empty on failure to avoid ghost data.
    }
  }

  /// Loads stored app settings into `appState` once to avoid ghost defaults.
  @MainActor
  private func loadAppSettingsFromPersistenceIfNeeded() async {
    let context = persistence.container.mainContext
    do {
      let descriptor = FetchDescriptor<SDAppSettings>()
      let stored = try context.fetch(descriptor)
      if let settings = stored.first {
        appState.defaultHorizonDays = settings.defaultHorizonDays
        appState.intervalSeconds = settings.intervalSeconds
        appState.diagnosticsEnabled = settings.diagnosticsEnabled
        appState.tasksURL = settings.tasksURL
      } else {
        // Create default settings if none exist
        let defaultSettings = SDAppSettings(
          defaultHorizonDays: appState.defaultHorizonDays,
          intervalSeconds: appState.intervalSeconds,
          diagnosticsEnabled: appState.diagnosticsEnabled,
          tasksURL: appState.tasksURL
        )
        context.insert(defaultSettings)
        try? context.save()
      }
    } catch {
      // Best-effort; leave defaults on failure to avoid ghost data.
    }
  }

  /// Saves current app settings to persistence.
  @MainActor
  private func saveAppSettings() {
    let context = persistence.container.mainContext
    do {
      let descriptor = FetchDescriptor<SDAppSettings>()
      let stored = try context.fetch(descriptor)
      if let settings = stored.first {
        settings.defaultHorizonDays = appState.defaultHorizonDays
        settings.intervalSeconds = appState.intervalSeconds
        settings.diagnosticsEnabled = appState.diagnosticsEnabled
        settings.tasksURL = appState.tasksURL
      } else {
        let newSettings = SDAppSettings(
          defaultHorizonDays: appState.defaultHorizonDays,
          intervalSeconds: appState.intervalSeconds,
          diagnosticsEnabled: appState.diagnosticsEnabled,
          tasksURL: appState.tasksURL
        )
        context.insert(newSettings)
      }
      try? context.save()
    } catch {
      // Best-effort; ignore failures to avoid disrupting user experience.
    }
  }
}

/// A reactive label for the menu bar that updates when syncing state changes.
struct MenuBarLabel: View {
  @ObservedObject var coordinator: SyncCoordinator
  
  var body: some View {
    if coordinator.isSyncing {
      HStack {
        Image(systemName: "arrow.triangle.2.circlepath")
          .symbolEffect(.variableColor.iterative.reversing)
        Text("Syncing")
      }
    } else {
      Image(systemName: "calendar.badge.clock")
    }
  }
}
