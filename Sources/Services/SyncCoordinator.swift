import EventKit
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
  ///   - tasksURL: Optional URL to send task data to via POST request.
  func syncNow(
    configs: [SyncConfigUI], defaultHorizonDays: Int, diagnosticsEnabled: Bool = true,
    tasksURL: String? = nil
  ) {
    Task { @MainActor in
      // Mark as actively syncing for UI feedback; ensure we reset even on early error.
      isSyncing = true
      lastStatus.lastMessage = "Syncing…"
      defer { isSyncing = false }
      do {
        for cfg in configs where cfg.enabled {
          let started = Date()

          // Diagnostics: resolve calendar titles and authorization status up-front for clarity.
          let store = EKEventStore()
          let auth = EKEventStore.authorizationStatus(for: .event)
          let authStr: String = {
            switch auth {
            case .fullAccess: return "fullAccess"
            case .authorized: return "authorized"
            case .writeOnly: return "writeOnly"
            case .restricted: return "restricted"
            case .denied: return "denied"
            case .notDetermined: return "notDetermined"
            @unknown default: return "unknown"
            }
          }()
          let srcTitle =
            store.calendar(withIdentifier: cfg.sourceCalendarId)?.title
            ?? "<missing:(\(cfg.sourceCalendarId))>"
          let tgtTitle =
            store.calendar(withIdentifier: cfg.targetCalendarId)?.title
            ?? "<missing:(\(cfg.targetCalendarId))>"
          print(
            "[Config] name=\(cfg.name) mode=\(cfg.mode) horizonDays=\(cfg.horizonDaysOverride ?? defaultHorizonDays) auth=\(authStr) source=\(srcTitle) target=\(tgtTitle)"
          )

          let plan = engine.buildPlan(config: cfg, defaultHorizonDays: defaultHorizonDays)
          do {
            try engine.apply(config: cfg, plan: plan)
            let finished = Date()
            if diagnosticsEnabled {
              // Derive counts from the concrete action list for accurate logging.
              // Why: Ensures created/updated/deleted match the actions we attempted to apply.
              var countedCreated = 0
              var countedUpdated = 0
              var countedDeleted = 0
              for a in plan.actions {
                switch a.kind {
                case .create: countedCreated += 1
                case .update: countedUpdated += 1
                case .delete: countedDeleted += 1
                }
              }
              // Quick writability diagnostic for the target calendar to aid troubleshooting.
              // Note: This is best-effort and does not affect sync logic.
              let targetWritableDiag: String = {
                let store = EKEventStore()
                if let cal = store.calendar(withIdentifier: cfg.targetCalendarId) {
                  return cal.allowsContentModifications ? "true" : "false"
                } else {
                  return "missing"
                }
              }()
              let log = SDSyncRunLog(
                id: UUID(),
                syncConfigId: cfg.id,
                startedAt: started,
                finishedAt: finished,
                resultRaw: "success",
                levelRaw: "info",
                created: countedCreated,
                updated: countedUpdated,
                deleted: countedDeleted,
                message:
                  "Applied \(plan.actions.count) actions (targetWritable=\(targetWritableDiag))"
              )
              modelContext.insert(log)
              // Persist per-action drill-down rows for this run, resolving created target IDs via mapping.
              for action in plan.actions {
                let kind: String = {
                  switch action.kind {
                  case .create: return "create"
                  case .update: return "update"
                  case .delete: return "delete"
                  }
                }()
                // Resolve a concrete target identifier for logging. For creates, pull from mapping inserted by apply().
                var resolvedTargetId: String? = action.target?.eventIdentifier
                if resolvedTargetId == nil, action.kind == .create, let se = action.source,
                  let srcId = se.eventIdentifier
                {
                  let (_, occISO, _) = SyncRules.occurrenceComponents(
                    sourceId: srcId, occurrenceDate: se.occurrenceDate, startDate: se.startDate)
                  let fetch = FetchDescriptor<SDEventMapping>(
                    predicate: #Predicate {
                      $0.syncConfigId == cfg.id && $0.sourceEventIdentifier == srcId
                        && $0.occurrenceDateKey == occISO
                    }
                  )
                  if let m = (try? modelContext.fetch(fetch))?.first {
                    resolvedTargetId = m.targetEventIdentifier
                  }
                }
                let al = SDSyncActionLog(
                  runLogId: log.id,
                  kindRaw: kind,
                  reason: action.reason,
                  sourceTitle: action.source?.title,
                  sourceStart: action.source?.startDate,
                  sourceEnd: action.source?.endDate,
                  targetTitle: action.target?.title,
                  targetStart: action.target?.startDate,
                  targetEnd: action.target?.endDate,
                  targetCalendarId: cfg.targetCalendarId,
                  targetEventIdentifier: resolvedTargetId
                )
                modelContext.insert(al)
              }
              // Recompute counts from the actions we just logged and verify apply outcomes.
              do {
                // Avoid capturing a model property directly inside the predicate; bind to a local constant first.
                let runId = log.id
                let fetch = FetchDescriptor<SDSyncActionLog>(
                  predicate: #Predicate { $0.runLogId == runId }
                )
                let acts: [SDSyncActionLog] = (try? modelContext.fetch(fetch)) ?? []
                let c = acts.filter { $0.kindRaw == "create" }.count
                let u = acts.filter { $0.kindRaw == "update" }.count
                let d = acts.filter { $0.kindRaw == "delete" }.count
                log.created = c
                log.updated = u
                log.deleted = d
                // Verify with EventKit to annotate applied/diagnostic for each action.
                let verifyStore = EKEventStore()
                var verifiedApplied = 0
                for a in acts {
                  switch a.kindRaw {
                  case "create":
                    if let id = a.targetEventIdentifier {
                      let exists = (verifyStore.event(withIdentifier: id) != nil)
                      a.applied = exists
                      a.diagnostic = exists ? nil : "Created event not found after save"
                    } else {
                      a.applied = nil
                      a.diagnostic = "No targetEventIdentifier recorded for create"
                    }
                  case "update":
                    if let id = a.targetEventIdentifier {
                      let exists = (verifyStore.event(withIdentifier: id) != nil)
                      a.applied = exists
                      a.diagnostic = exists ? nil : "Updated event not found after save"
                    } else {
                      a.applied = nil
                      a.diagnostic = "No targetEventIdentifier to verify update"
                    }
                  case "delete":
                    // Verify delete by time window and marker presence instead of eventIdentifier,
                    // because occurrences share identifiers with the series master in EventKit.
                    if let calId = a.targetCalendarId,
                      let cal = verifyStore.calendar(withIdentifier: calId),
                      let start = a.targetStart, let end = a.targetEnd
                    {
                      let pred = verifyStore.predicateForEvents(
                        withStart: start.addingTimeInterval(-1), end: end.addingTimeInterval(1),
                        calendars: [cal])
                      let evs = verifyStore.events(matching: pred)
                      let stillPresent = evs.contains { ev in
                        // Match by exact times and presence of our marker.
                        ev.startDate == start && ev.endDate == end
                          && (SyncRules.extractMarker(
                            notes: ev.notes, urlString: ev.url?.absoluteString) != nil)
                      }
                      a.applied = !stillPresent
                      a.diagnostic =
                        stillPresent ? "Event instance with marker still present at time" : nil
                    } else {
                      a.applied = nil
                      a.diagnostic =
                        "Insufficient data to verify delete (missing calendar or times)"
                    }
                  default:
                    a.applied = nil
                  }
                  if a.applied == true { verifiedApplied += 1 }
                }
                // Reflect counts and verification summary in the message for quick scanning.
                log.message =
                  "Applied \(acts.count) actions (targetWritable=\(targetWritableDiag)) c/u/d=\(c)/\(u)/\(d) verifiedApplied=\(verifiedApplied)"
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

        // Handle task sync if URL is provided
        if let tasksURL = tasksURL, !tasksURL.isEmpty {
          lastStatus.lastMessage = "Syncing tasks…"
          do {
            // Check if we have reminder access, if not, request it
            let reminderAuth = EKEventStore.authorizationStatus(for: .reminder)
            if reminderAuth == .notDetermined {
              print("[TaskSync] Requesting reminder access...")
              // Note: We can't request access from here as it needs to be done on the main thread
              // and with proper user interaction. For now, we'll just log the issue.
              print("[TaskSync] Reminder access not granted, skipping task sync")
              lastStatus.lastMessage = "Task sync skipped - reminder access required"
            } else if reminderAuth == .denied || reminderAuth == .restricted {
              print("[TaskSync] Reminder access denied or restricted, skipping task sync")
              lastStatus.lastMessage = "Task sync skipped - reminder access denied"
            } else {
              let tasks = await engine.fetchTasks(horizonDays: defaultHorizonDays)
              let taskService = TaskSyncService()
              let success = await taskService.sendTasks(tasks, to: tasksURL)
              if success {
                print("[TaskSync] Successfully sent \(tasks.count) tasks to \(tasksURL)")
                lastStatus.lastMessage = "Task sync completed"
              } else {
                print("[TaskSync] Failed to send tasks to \(tasksURL)")
                lastStatus.lastMessage = "Task sync failed"
              }
            }
          } catch {
            print("[TaskSync] Error during task sync: \(error.localizedDescription)")
            lastStatus.lastMessage = "Task sync error"
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
    print("Purging all managed target items")
    Task { @MainActor in
      isSyncing = true
      lastStatus.lastMessage = "Purging…"
      defer { isSyncing = false }
      do {
        print("Purging all managed target items")
        // Deduplicate all target calendars across provided configs, considering only enabled ones.
        // Why: The user intent is to purge items from calendars that are actively used by syncs.
        // Disabled syncs should not influence which calendars are purged.
        let started = Date()
        // Execute purge and capture per-event details and diagnostics for logging.
        let purge = try engine.purgeManagedTargets()
        let finished = Date()
        if diagnosticsEnabled {
          // Record a single aggregate log without a specific syncConfigId context.
          // Build a human-readable per-calendar diagnostics summary string.
          let summariesString: String = {
            guard !purge.summaries.isEmpty else { return "calendars: []" }
            let parts = purge.summaries.map { s in
              let writable = s.allowsModifications ? "writable" : "read-only"
              return
                "\(s.calendarTitle) [\(writable)] enum=\(s.enumeratedCount) match=\(s.brandingMatchCount) del=\(s.deletedCount)"
            }
            return "calendars: [" + parts.joined(separator: "; ") + "]"
          }()
          let message =
            "Purged managed items (auth=\(purge.authStatus)); \(summariesString)"
          let log = SDSyncRunLog(
            id: UUID(),
            syncConfigId: UUID(),
            startedAt: started,
            finishedAt: finished,
            resultRaw: "success",
            levelRaw: "info",
            created: 0,
            updated: 0,
            deleted: purge.deleted,
            message: message
          )
          modelContext.insert(log)
          // Persist detailed action logs for each purged event to surface in Logs UI.
          // Why: Users requested visibility into which concrete items were removed.
          for d in purge.details {
            let al = SDSyncActionLog(
              runLogId: log.id,
              kindRaw: "delete",
              reason: "Purged managed event",
              sourceTitle: nil,
              sourceStart: nil,
              sourceEnd: nil,
              targetTitle: d.targetTitle,
              targetStart: d.targetStart,
              targetEnd: d.targetEnd,
              targetCalendarId: d.calendarId,
              targetEventIdentifier: d.targetEventIdentifier
            )
            modelContext.insert(al)
          }
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
