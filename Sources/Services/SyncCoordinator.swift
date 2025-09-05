import Foundation
import SwiftData

/// Coordinates running syncs for all enabled configurations.
@MainActor
final class SyncCoordinator: ObservableObject {
    private let engine: SyncEngine
    private let modelContext: ModelContext
    @Published var lastStatus: LastRunStatus = LastRunStatus(lastSuccessAt: nil, lastFailureAt: nil, lastMessage: nil)

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.engine = SyncEngine(modelContext: modelContext)
    }

    /// Triggers sync for provided configs, optionally writing logs based on diagnostics flag.
    /// - Parameters:
    ///   - configs: Sync tuples to run.
    ///   - defaultHorizonDays: Default horizon used when config has no override.
    ///   - diagnosticsEnabled: When false, avoid persisting logs to SwiftData.
    func syncNow(configs: [SyncConfigUI], defaultHorizonDays: Int, diagnosticsEnabled: Bool = true) {
        Task { @MainActor in
            do {
                for cfg in configs where cfg.enabled {
                    let started = Date()
                    let plan = engine.buildPlan(config: cfg, defaultHorizonDays: defaultHorizonDays)
                    do {
                        try engine.apply(config: cfg, plan: plan)
                        let finished = Date()
                        if diagnosticsEnabled {
                            let log = SDSyncRunLog(
                                id: UUID(),
                                syncConfigId: cfg.id,
                                startedAt: started,
                                finishedAt: finished,
                                resultRaw: "success",
                                levelRaw: "info",
                                created: plan.created,
                                updated: plan.updated,
                                deleted: plan.deleted,
                                message: "Applied \(plan.actions.count) actions"
                            )
                            modelContext.insert(log)
                        }
                    } catch {
                        let finished = Date()
                        if diagnosticsEnabled {
                            let log = SDSyncRunLog(
                                id: UUID(),
                                syncConfigId: cfg.id,
                                startedAt: started,
                                finishedAt: finished,
                                resultRaw: "failure",
                                levelRaw: "error",
                                created: plan.created,
                                updated: plan.updated,
                                deleted: plan.deleted,
                                message: "Error: \(error.localizedDescription)"
                            )
                            modelContext.insert(log)
                        }
                        throw error
                    }
                }
                if diagnosticsEnabled { try? modelContext.save() }
                lastStatus.lastSuccessAt = Date()
                lastStatus.lastMessage = "Sync completed"
            } catch {
                lastStatus.lastFailureAt = Date()
                lastStatus.lastMessage = "Sync failed: \(error.localizedDescription)"
            }
        }
    }
}


