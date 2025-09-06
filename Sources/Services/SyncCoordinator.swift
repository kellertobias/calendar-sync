import Foundation
import SwiftData

/// Coordinates running syncs for all enabled configurations.
@MainActor
final class SyncCoordinator: ObservableObject {
  private let engine: SyncEngine
  private let modelContext: ModelContext
  @Published var lastStatus: LastRunStatus = LastRunStatus(
    lastSuccessAt: nil, lastFailureAt: nil, lastMessage: nil)
  /// Indicates whether a sync operation is currently running.
  /// Why: Allows the UI (menu and windows) to reflect live activity with a spinner or label.
  @Published var isSyncing: Bool = false

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
      // Mark as actively syncing for UI feedback; ensure we reset even on early error.
      isSyncing = true
      lastStatus.lastMessage = "Syncing…"
      defer { isSyncing = false }
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
              // Persist per-action drill-down rows for this run.
              for action in plan.actions {
                let kind: String = {
                  switch action.kind {
                  case .create: return "create"
                  case .update: return "update"
                  case .delete: return "delete"
                  }
                }()
                let al = SDSyncActionLog(
                  runLogId: log.id,
                  kindRaw: kind,
                  reason: action.reason,
                  sourceTitle: action.source?.title,
                  sourceStart: action.source?.startDate,
                  sourceEnd: action.source?.endDate,
                  targetTitle: action.target?.title,
                  targetStart: action.target?.startDate,
                  targetEnd: action.target?.endDate
                )
                modelContext.insert(al)
              }
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

  /// Purges all managed target items (by marker) across the provided configs.
  /// - Parameters:
  ///   - configs: Tuples whose managed items should be removed from their target calendars.
  ///   - diagnosticsEnabled: When true, writes a run log per config capturing delete counts.
  func purgeAll(configs: [SyncConfigUI], diagnosticsEnabled: Bool = true) {
    Task { @MainActor in
      isSyncing = true
      lastStatus.lastMessage = "Purging…"
      defer { isSyncing = false }
      do {
        // Deduplicate all target calendars across provided configs (even if disabled).
        let targetIds = Array(Set(configs.map { $0.targetCalendarId }))
        let started = Date()
        let deleted = try engine.purgeManagedTargets(in: targetIds)
        let finished = Date()
        if diagnosticsEnabled {
          // Record a single aggregate log without a specific syncConfigId context.
          let log = SDSyncRunLog(
            id: UUID(),
            syncConfigId: UUID(),
            startedAt: started,
            finishedAt: finished,
            resultRaw: "success",
            levelRaw: "info",
            created: 0,
            updated: 0,
            deleted: deleted,
            message: "Purged managed items from \(targetIds.count) calendars"
          )
          modelContext.insert(log)
        }
        if diagnosticsEnabled { try? modelContext.save() }
        lastStatus.lastSuccessAt = Date()
        lastStatus.lastMessage = "Purge completed"
      } catch {
        lastStatus.lastFailureAt = Date()
        lastStatus.lastMessage = "Purge failed: \(error.localizedDescription)"
      }
    }
  }
}
