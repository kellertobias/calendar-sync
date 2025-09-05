import SwiftUI

/// Lazily constructs a scheduler tied to the coordinator and app state.
@MainActor
final class SchedulerHolder: ObservableObject {
    private var cached: SyncScheduler?

    func scheduler(coordinator: SyncCoordinator, appState: AppState) -> SyncScheduler {
        if let s = cached { return s }
        let s = SyncScheduler(coordinator: coordinator, appState: appState)
        cached = s
        return s
    }
}


