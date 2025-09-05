import SwiftData
import Combine
import SwiftUI

/// Lazily constructs a single SyncCoordinator bound to the model context.
@MainActor
final class CoordinatorHolder: ObservableObject {
    private var cached: SyncCoordinator?

    func coordinator(modelContext: ModelContext) -> SyncCoordinator {
        if let c = cached { return c }
        let c = SyncCoordinator(modelContext: modelContext)
        cached = c
        return c
    }
}


