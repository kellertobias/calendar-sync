import SwiftUI
import SwiftData
import AppKit

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
        MenuBarExtra("Calendar Sync", systemImage: "calendar.badge.clock") {
            MenuContentView()
                .environmentObject(appState)
                .environmentObject(eventKitAuth)
                .environmentObject(calendars)
                .modelContainer(persistence.container)
                .environmentObject(coordinatorHolder.coordinator(modelContext: persistence.container.mainContext))
                .task {
                    // Ensure syncs are loaded even if only the menu is opened.
                    await loadSyncsFromPersistenceIfNeeded()
                    calendars.reload(authorized: eventKitAuth.hasReadAccess)
                    appState.availableCalendars = calendars.calendars
                }
        }

        // Settings window for permissions and intervals (dedicated id)
        WindowGroup("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(eventKitAuth)
                .environmentObject(calendars)
                .modelContainer(persistence.container)
                .environmentObject(coordinatorHolder.coordinator(modelContext: persistence.container.mainContext))
                .task {
                    calendars.reload(authorized: eventKitAuth.hasReadAccess)
                    appState.availableCalendars = calendars.calendars
                    // Load syncs from SwiftData only once on first launch into this window.
                    await loadSyncsFromPersistenceIfNeeded()
                    schedulerHolder.scheduler(coordinator: coordinatorHolder.coordinator(modelContext: persistence.container.mainContext), appState: appState).start()
                }
        }

        // Window for managing sync tuples (UI-first stub)
        WindowGroup("Syncs", id: "syncs") {
            SyncListView()
                .environmentObject(appState)
                .environmentObject(eventKitAuth)
                .environmentObject(calendars)
                .modelContainer(persistence.container)
                .environmentObject(coordinatorHolder.coordinator(modelContext: persistence.container.mainContext))
                .task {
                    calendars.reload(authorized: eventKitAuth.hasReadAccess)
                    appState.availableCalendars = calendars.calendars
                    await loadSyncsFromPersistenceIfNeeded()
                    schedulerHolder.scheduler(coordinator: coordinatorHolder.coordinator(modelContext: persistence.container.mainContext), appState: appState).start()
                }
        }
        .defaultSize(width: 680, height: 520)
        .onChange(of: appState.intervalSeconds) { _, _ in
            schedulerHolder.scheduler(coordinator: coordinatorHolder.coordinator(modelContext: persistence.container.mainContext), appState: appState).start()
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

        // Logs window
        WindowGroup("Logs", id: "logs") {
            LogsView()
                .environmentObject(appState)
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
}

