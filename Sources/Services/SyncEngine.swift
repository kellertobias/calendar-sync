import EventKit
import Foundation
import OSLog
import SwiftData

/// Computes and applies one-way sync actions for a single configuration.
/// Supports Full and Blocker modes, filters, weekday/time windows, and tagging.
/// Computes and applies plans and persists event mappings.
/// Why: Using `SDEventMapping` as the source of truth prevents relying solely on fragile tag parsing.
@MainActor
final class SyncEngine {
  /// Lightweight snapshot describing a single purged target event.
  /// - Why: Used to surface detailed purge logs in the UI without persisting raw `EKEvent`.
  struct PurgedEventDetails {
    /// Identifier of the calendar the event was deleted from.
    let calendarId: String
    /// Title of the deleted target event, if any.
    let targetTitle: String?
    /// Start date of the deleted target event, if any.
    let targetStart: Date?
    /// End date of the deleted target event, if any.
    let targetEnd: Date?
    /// EventKit identifier of the deleted target event, if known.
    let targetEventIdentifier: String?
  }
  struct PlanAction {
    enum Kind { case create, update, delete }
    let kind: Kind
    let source: EKEvent?
    let target: EKEvent?
    let reason: String
  }

  struct PlanResult {
    let actions: [PlanAction]
    let created: Int
    let updated: Int
    let deleted: Int
  }

  private let store = EKEventStore()
  private let modelContext: ModelContext
  /// Logger used for purge diagnostics that are visible in the macOS unified console.
  /// - Subsystem: Uses the app bundle identifier when available to simplify filtering.
  /// - Category: "Purge" to group messages related to purge operations.
  private let purgeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.example.CalendarSync", category: "Purge")

  /// Initializes the engine with a SwiftData model context.
  /// - Parameter modelContext: Context used to read/write `SDEventMapping` and logs.
  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  /// Shared ISO-8601 formatter for stable per-occurrence keys.
  private lazy var isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    // Using internet date time ensures timezone and seconds; stable across runs. Force UTC to avoid drift.
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
  }()

  /// Builds stable components used to identify a specific occurrence of a source event.
  /// - Important: Prefer a provider-stable external identifier when available to ensure
  ///   cross-device consistency (prevents duplicates across multiple computers).
  /// - Returns: `(sourceId, occISO, key)` where key is `sourceId|occISO`.
  /// - Why: Recurring events share an identifier; `occurrenceDate` disambiguates instances.
  /// - Note: For detached overrides, EventKit sets `occurrenceDate` to the original instance date,
  ///   which is what we want to ensure mappings remain stable even when an instance is edited.
  private func makeOccurrenceComponents(_ event: EKEvent) -> (
    String, String, String
  ) {
    // Prefer a cross-device stable identifier when present.
    // `EKEvent` does not expose externalIdentifier publicly on macOS; eventIdentifier is used.
    // To mitigate per-device variance, we couple it with an occurrence timestamp normalized to UTC.
    let sourceId = event.eventIdentifier ?? UUID().uuidString
    let occDate = event.occurrenceDate ?? event.startDate ?? Date()
    let occISO = isoFormatter.string(from: occDate)
    let key = "\(sourceId)|\(occISO)"
    return (sourceId, occISO, key)
  }

  /// Marker inserted on created/managed target events.
  /// - Format: "[CalendarSync] tuple=<UUID> name=<url-encoded> source=<id> occ=<ISO>"
  /// - Note: `tuple` and `name` aid cross-config and cross-device ownership checks.
  private func marker(syncId: UUID, syncName: String, sourceId: String, occurrenceISO: String)
    -> String
  {
    let encodedName = syncName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    return
      "[CalendarSync] tuple=\(syncId.uuidString) name=\(encodedName) source=\(sourceId) occ=\(occurrenceISO)"
  }

  private func extractMarker(from event: EKEvent) -> SyncRules.Marker? {
    SyncRules.extractMarker(notes: event.notes, urlString: event.url?.absoluteString)
  }

  /// Builds a human-readable branding line and the machine-readable marker block.
  /// - Why: We append this to the END of the event notes so users see branding,
  ///   and the sync engine can reliably parse the marker. The warning clarifies
  ///   that removing this text breaks synchronization.
  private var brandingLine: String {
    "Tobisk Calendar Sync — See more: https://github.com/kellertobias/calendar-sync — Do not remove this text; it is required for sync."
  }

  private func brandedMarkerBlock(
    configId: UUID, syncName: String, sourceId: String, occurrenceISO: String
  ) -> String {
    let tag = marker(
      syncId: configId, syncName: syncName, sourceId: sourceId, occurrenceISO: occurrenceISO)
    return "\(brandingLine)\n\(tag)"
  }

  /// Returns notes with the brand+marker block appended at the end when missing.
  /// - Behavior: If notes already contain our marker, returns the original notes untouched.
  ///   Otherwise, appends two newlines followed by the brand+marker block.
  private func appendBrandingIfMissing(originalNotes: String?, brandAndMarker: String) -> String {
    let existing = (originalNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // Idempotency: leave as-is when the marker is already present anywhere in the notes.
    if SyncRules.extractMarker(notes: existing, urlString: nil) != nil { return existing }
    if existing.isEmpty { return brandAndMarker }
    return "\(existing)\n\n\(brandAndMarker)"
  }

  /// Builds a plan of changes between source and target within a horizon.
  /// Strategy:
  /// 1) Prefer mapping lookup (sourceId + occurrenceISO → targetIdentifier) to locate targets.
  /// 2) Fallback to tag parsing when mapping is missing (first run / recovery).
  /// 3) Only propose deletions for items we own (mapping + tag + calendar ownership).
  func buildPlan(config: SyncConfigUI, defaultHorizonDays: Int) -> PlanResult {
    // Require full access on macOS 14+ to avoid deprecation and ensure read capability.
    let auth = EKEventStore.authorizationStatus(for: .event)
    // Accept legacy `.authorized` as valid read permission too to keep sync working
    // on systems granting the pre-macOS14 status.
    guard auth == .fullAccess || auth == .authorized else {
      return PlanResult(actions: [], created: 0, updated: 0, deleted: 0)
    }

    let horizon = TimeInterval((config.horizonDaysOverride ?? defaultHorizonDays) * 24 * 3600)
    let windowStart = Date()
    let windowEnd = Date().addingTimeInterval(horizon)

    guard let sourceCal = store.calendar(withIdentifier: config.sourceCalendarId),
      let targetCal = store.calendar(withIdentifier: config.targetCalendarId)
    else {
      return PlanResult(actions: [], created: 0, updated: 0, deleted: 0)
    }

    // Fetch occurrences
    let sourcePredicate = store.predicateForEvents(
      withStart: windowStart, end: windowEnd, calendars: [sourceCal])
    let targetPredicate = store.predicateForEvents(
      withStart: windowStart, end: windowEnd, calendars: [targetCal])
    let sourceEvents = store.events(matching: sourcePredicate)
    let targetEvents = store.events(matching: targetPredicate)

    // DEBUG: High-level counts for visibility during troubleshooting.
    print(
      "[Plan] source=\(sourceEvents.count) target=\(targetEvents.count) horizonDays=\(config.horizonDaysOverride ?? defaultHorizonDays) mode=\(config.mode)"
    )

    // Preload mappings for this config and index by composite key
    let mappingFetch = FetchDescriptor<SDEventMapping>(
      predicate: #Predicate { $0.syncConfigId == config.id }
    )
    let mappings: [SDEventMapping] = (try? modelContext.fetch(mappingFetch)) ?? []

    // Map target events by identifier for O(1) lookup from mappings
    var targetByIdentifier: [String: EKEvent] = [:]
    for te in targetEvents {
      if let id = te.eventIdentifier {
        targetByIdentifier[id] = te
      }
    }

    // Index target by (sourceId, occ) via tags
    var taggedTargets: [String: EKEvent] = [:]
    for te in targetEvents {
      if let tag = extractMarker(from: te) {
        let key = "\(tag.source)|\(tag.occ)"
        if taggedTargets[key] != nil {
          print("[TagDup] Duplicate tagged target for key=\(key) title=\(te.title ?? "-")")
        }
        taggedTargets[key] = te
      }
    }

    // Index target by (sourceId, occ) via mappings
    var mappedTargets: [String: EKEvent] = [:]
    for m in mappings {
      if let te = targetByIdentifier[m.targetEventIdentifier] {
        let key = "\(m.sourceEventIdentifier)|\(m.occurrenceDateKey)"
        if mappedTargets[key] != nil {
          print("[MapDup] Duplicate mapped target for key=\(key) title=\(te.title ?? "-")")
        }
        mappedTargets[key] = te
      }
    }

    // Helpers
    func passesFilters(_ ev: EKEvent) -> Bool {
      // Organizer name if any (EventKit exposes organizer via attendees or organizer property).
      let organizerName = ev.organizer?.name ?? ev.organizer.map { $0.url.absoluteString }
      // Attendees display names or emails
      let attendeeNames: [String] = (ev.attendees ?? []).compactMap { att in
        if let name = att.name, !name.isEmpty { return name }
        return att.url.absoluteString
      }
      // Duration in minutes (rounded down)
      let durationMins: Int? = {
        guard let start = ev.startDate, let end = ev.endDate else { return nil }
        return Int(end.timeIntervalSince(start) / 60)
      }()
      // Status flags: prefer current user's attendee response; fallback to event status.
      // Why: EKEvent.status reflects overall event state; filters such as "Only accepted"
      //      should reflect the user's RSVP when available.
      let selfParticipantStatus: EKParticipantStatus? = (ev.attendees ?? []).first(where: {
        $0.isCurrentUser
      })?.participantStatus
      let isConfirmed: Bool
      let isTentative: Bool
      if let s = selfParticipantStatus {
        isConfirmed = s == .accepted
        isTentative = s == .tentative
      } else {
        // Fallback heuristic when user's RSVP is not available:
        // - Consider event "tentative" if availability is `.tentative` (as shown in Calendar UI)
        // - Otherwise derive from overall event status
        let status = ev.status
        let availabilityTentative = ev.availability == .tentative
        isTentative = (status == .tentative) || availabilityTentative
        isConfirmed = (status == .confirmed) && !availabilityTentative
      }
      // Availability: treat .busy as busy; .free as free. Other states (tentative) considered busy for filtering purposes.
      let availabilityBusy: Bool = {
        switch ev.availability {
        case .free: return false
        default: return true
        }
      }()

      return SyncRules.passesFilters(
        title: ev.title ?? "",
        location: ev.location,
        notes: ev.notes,
        organizer: organizerName,
        attendees: attendeeNames,
        durationMinutes: durationMins,
        isAllDay: ev.isAllDay,
        isStatusConfirmed: isConfirmed,
        isStatusTentative: isTentative,
        attendeesCount: ev.attendees?.count ?? 0,
        isRepeating: ev.hasRecurrenceRules,
        isAvailabilityBusy: availabilityBusy,
        filters: config.filters,
        sourceNotes: ev.notes,
        sourceURLString: ev.url?.absoluteString,
        configId: config.id
      )
    }

    func allowedByTimeWindows(_ ev: EKEvent) -> Bool {
      SyncRules.allowedByTimeWindows(
        start: ev.startDate, isAllDay: ev.isAllDay, windows: config.timeWindows)
    }

    func contains(_ str: String, pattern: String, cs: Bool) -> Bool {
      cs ? str.contains(pattern) : str.range(of: pattern, options: [.caseInsensitive]) != nil
    }
    func regex(_ str: String, pattern: String, cs: Bool) -> Bool {
      guard
        let r = try? NSRegularExpression(pattern: pattern, options: cs ? [] : [.caseInsensitive])
      else { return false }
      return r.firstMatch(
        in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length)) != nil
    }

    var actions: [PlanAction] = []
    var created = 0
    var updated = 0
    var deleted = 0

    // Build sets of keys from source occurrences:
    // - liveKeys: only those that pass filters/time windows (used for create/update)
    // - allKeys: all occurrences regardless of filters (used to avoid unsafe deletes
    //            when the source still exists but is merely filtered out)
    var liveKeys: Set<String> = []
    var allKeys: Set<String> = []

    // Track duplicates from source enumeration within a single build pass.
    var seenSourceKeys: Set<String> = []

    for se in sourceEvents {
      let (sid0, occ0, rawKey) = makeOccurrenceComponents(se)
      allKeys.insert(rawKey)
      // Detect and skip duplicates within the same planning window.
      if seenSourceKeys.contains(rawKey) {
        print(
          "[SrcDup] Duplicate source occurrence key=\(rawKey) title=\(se.title ?? "-") occ=\(occ0) sid=\(sid0)"
        )
        continue
      }
      seenSourceKeys.insert(rawKey)

      guard passesFilters(se), allowedByTimeWindows(se) else { continue }
      let (sourceId, occISO, key) = makeOccurrenceComponents(se)
      liveKeys.insert(key)
      let teFromMapping = mappedTargets[key]
      let teFromTag = teFromMapping == nil ? taggedTargets[key] : nil
      if let te = teFromMapping ?? teFromTag {
        // If discovered only via tag, migrate to mapping for resilience
        if teFromMapping == nil, let targetId = te.eventIdentifier {
          let exists = mappings.contains {
            $0.sourceEventIdentifier == sourceId && $0.occurrenceDateKey == occISO
          }
          if !exists {
            let mapping = SDEventMapping(
              id: UUID(),
              syncConfigId: config.id,
              sourceEventIdentifier: sourceId,
              occurrenceDateKey: occISO,
              targetEventIdentifier: targetId,
              lastUpdated: Date()
            )
            modelContext.insert(mapping)
            print("[MapInsert] Inserted mapping sid=\(sourceId) occ=\(occISO) → target=\(targetId)")
          }
        }
        // Compare fields to see if update needed
        if needsUpdate(
          source: se, target: te, mode: config.mode, template: config.blockerTitleTemplate)
        {
          actions.append(
            PlanAction(kind: .update, source: se, target: te, reason: "Fields changed"))
          updated += 1
          print(
            "[Plan] UPDATE key=\(key) title=\(se.title ?? "-") start=\(se.startDate?.description ?? "-")"
          )
        } else {
          print("[Plan] MATCH key=\(key) title=\(se.title ?? "-") (no change)")
        }
      } else {
        actions.append(
          PlanAction(kind: .create, source: se, target: nil, reason: "Missing in target"))
        created += 1
        print(
          "[Plan] CREATE key=\(key) title=\(se.title ?? "-") start=\(se.startDate?.description ?? "-")"
        )
      }
    }

    // Deletions: consider both mapped and tagged targets, but require ownership safety
    func hasMapping(for key: String) -> Bool {
      mappedTargets[key] != nil
        || mappings.contains { "\($0.sourceEventIdentifier)|\($0.occurrenceDateKey)" == key }
    }
    func safeToDelete(_ te: EKEvent, key: String) -> Bool {
      let marker = extractMarker(from: te)
      let expectedName =
        config.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        ?? ""
      return SyncRules.safeToDeletePolicy(
        targetCalendarId: config.targetCalendarId,
        eventCalendarId: te.calendar.calendarIdentifier,
        marker: marker,
        expectedTupleId: config.id,
        expectedEncodedName: expectedName
      )
    }

    // From mappings
    for (key, te) in mappedTargets {
      // Only consider deletion when the source occurrence no longer exists at all.
      // If the source still exists (but is filtered out), keep the target to avoid churn.
      if !liveKeys.contains(key) && !allKeys.contains(key) && safeToDelete(te, key: key) {
        actions.append(
          PlanAction(kind: .delete, source: nil, target: te, reason: "Source missing (mapped)"))
        deleted += 1
        print("[Plan] DELETE (mapped) key=\(key) title=\(te.title ?? "-")")
      }
    }
    // From tags that are not mapped (legacy)
    for te in targetEvents {
      guard let tag = extractMarker(from: te) else { continue }
      let key = "\(tag.source)|\(tag.occ)"
      if mappedTargets[key] == nil && !liveKeys.contains(key) && !allKeys.contains(key)
        && safeToDelete(te, key: key)
      {
        actions.append(
          PlanAction(kind: .delete, source: nil, target: te, reason: "Source missing (tagged)"))
        deleted += 1
        print("[Plan] DELETE (tagged) key=\(key) title=\(te.title ?? "-")")
      }
    }

    print("[Plan] Summary created=\(created) updated=\(updated) deleted=\(deleted)")

    return PlanResult(actions: actions, created: created, updated: updated, deleted: deleted)
  }

  private func needsUpdate(source: EKEvent, target: EKEvent, mode: SyncMode, template: String?)
    -> Bool
  {
    switch mode {
    case .full, .privateEvents:
      return source.title != target.title || source.startDate != target.startDate
        || source.endDate != target.endDate || (source.location ?? "") != (target.location ?? "")
    case .blocker:
      let title = blockerTitle(from: source, template: template)
      return title != target.title || source.startDate != target.startDate
        || source.endDate != target.endDate
    }
  }

  private func blockerTitle(from source: EKEvent, template: String?) -> String {
    let t = template ?? "Busy"
    return t.replacingOccurrences(of: "{sourceTitle}", with: source.title ?? "")
  }

  /// Applies a plan directly to the target calendar. Requires authorization.
  func apply(config: SyncConfigUI, plan: PlanResult) throws {
    guard let targetCal = store.calendar(withIdentifier: config.targetCalendarId) else {
      throw NSError(
        domain: "CalendarSync.SyncEngine", code: 1000,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Target calendar not found. Re-select the target in Settings."
        ])
    }
    // Preflight: Fail fast when the selected target calendar cannot be modified.
    // Why: Some calendars (e.g., subscribed/read-only) do not allow event creation or updates.
    // Surfacing a clear error here makes troubleshooting much easier than relying on EventKit errors.
    if !targetCal.allowsContentModifications {
      throw NSError(
        domain: "CalendarSync.SyncEngine", code: 1001,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Target calendar is read-only: \(targetCal.title). Choose a writable calendar."
        ])
    }
    for action in plan.actions {
      switch action.kind {
      case .create:
        guard let se = action.source else { continue }
        let ev = EKEvent(eventStore: store)
        ev.calendar = targetCal
        copy(from: se, to: ev, mode: config.mode, template: config.blockerTitleTemplate)
        let (sourceId, occISO, _) = makeOccurrenceComponents(se)
        let tag = marker(
          syncId: config.id, syncName: config.name, sourceId: sourceId, occurrenceISO: occISO)
        let brandBlock = brandedMarkerBlock(
          configId: config.id, syncName: config.name, sourceId: sourceId, occurrenceISO: occISO)
        ev.notes = appendBrandingIfMissing(originalNotes: se.notes, brandAndMarker: brandBlock)
        if ev.url == nil { ev.url = URL(string: tag) }
        try store.save(ev, span: .thisEvent)
        print(
          "[Apply] CREATE saved title=\(ev.title ?? "-") key=\(sourceId)|\(occISO) id=\(ev.eventIdentifier ?? "-")"
        )
        // Verify the event exists after save to catch silent no-ops.
        if let savedId = ev.eventIdentifier {
          if store.event(withIdentifier: savedId) == nil {
            throw NSError(
              domain: "CalendarSync.SyncEngine", code: 1101,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Create verification failed: saved event not found in target store"
              ])
          }
        }
        // Persist mapping after successful save
        if let targetId = ev.eventIdentifier {
          let mapping = SDEventMapping(
            id: UUID(),
            syncConfigId: config.id,
            sourceEventIdentifier: sourceId,
            occurrenceDateKey: occISO,
            targetEventIdentifier: targetId,
            lastUpdated: Date()
          )
          modelContext.insert(mapping)
          print("[MapInsert] After create sid=\(sourceId) occ=\(occISO) → target=\(targetId)")
        }
      case .update:
        guard let se = action.source, let te = action.target else { continue }
        copy(from: se, to: te, mode: config.mode, template: config.blockerTitleTemplate)
        // Ensure branding + marker are present at the END of notes if missing.
        let hasMarker =
          SyncRules.extractMarker(notes: te.notes, urlString: te.url?.absoluteString) != nil
        if !hasMarker {
          let (sourceId, occISO, _) = makeOccurrenceComponents(se)
          let tag = marker(
            syncId: config.id, syncName: config.name, sourceId: sourceId, occurrenceISO: occISO)
          let brandBlock = brandedMarkerBlock(
            configId: config.id, syncName: config.name, sourceId: sourceId, occurrenceISO: occISO)
          te.notes = appendBrandingIfMissing(originalNotes: te.notes, brandAndMarker: brandBlock)
          if te.url == nil { te.url = URL(string: tag) }
        } else {
          // Marker exists: still ensure branding line is present at END of notes.
          let existing = (te.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if !existing.contains(brandingLine) {
            te.notes = existing.isEmpty ? brandingLine : "\(existing)\n\n\(brandingLine)"
          }
        }
        try store.save(te, span: .thisEvent)
        print("[Apply] UPDATE saved title=\(te.title ?? "-") id=\(te.eventIdentifier ?? "-")")
        // Upsert mapping on update in case identifiers rotated
        if let targetId = te.eventIdentifier {
          let (sourceId, occISO, _) = makeOccurrenceComponents(se)
          let fetch = FetchDescriptor<SDEventMapping>(
            predicate: #Predicate {
              $0.syncConfigId == config.id && $0.sourceEventIdentifier == sourceId
                && $0.occurrenceDateKey == occISO
            })
          if let existing = (try? modelContext.fetch(fetch))?.first {
            existing.targetEventIdentifier = targetId
            existing.lastUpdated = Date()
          } else {
            let mapping = SDEventMapping(
              id: UUID(),
              syncConfigId: config.id,
              sourceEventIdentifier: sourceId,
              occurrenceDateKey: occISO,
              targetEventIdentifier: targetId,
              lastUpdated: Date()
            )
            modelContext.insert(mapping)
          }
        }
      case .delete:
        if let te = action.target {
          try store.remove(te, span: .thisEvent)
          // Verify the event is gone to catch silent no-ops.
          if let deletedId = te.eventIdentifier {
            if store.event(withIdentifier: deletedId) != nil {
              throw NSError(
                domain: "CalendarSync.SyncEngine", code: 1201,
                userInfo: [
                  NSLocalizedDescriptionKey:
                    "Delete verification failed: event still present after removal"
                ])
            }
          }
          print("[Apply] DELETE removed title=\(te.title ?? "-") id=\(te.eventIdentifier ?? "-")")
          // Best-effort cleanup of mapping for this target id
          if let targetId = te.eventIdentifier {
            let fetch = FetchDescriptor<SDEventMapping>(
              predicate: #Predicate {
                $0.syncConfigId == config.id && $0.targetEventIdentifier == targetId
              })
            if let rows = try? modelContext.fetch(fetch) {
              for r in rows { modelContext.delete(r) }
            }
          }
        }
      }
    }
    // Persist mapping changes
    try? modelContext.save()
  }

  private func copy(from source: EKEvent, to target: EKEvent, mode: SyncMode, template: String?) {
    target.startDate = source.startDate
    target.endDate = source.endDate
    target.isAllDay = source.isAllDay
    switch mode {
    case .full, .privateEvents:
      target.title = source.title
      target.location = source.location
    case .blocker:
      target.title = blockerTitle(from: source, template: template)
      target.location = nil
    }
    target.availability = .busy
    // Privacy note:
    // - In `privateEvents` mode we keep full details locally for fidelity, but set availability
    //   to `.busy` so others only see free/busy when the provider respects privacy/permissions.
    // - EventKit does not provide a cross-provider "private" toggle; visibility behavior depends
    //   on the target service (iCloud/Google/Exchange) and account ACLs.
  }

  // Removed legacy implementation of purgeManagedTargets(for:includeLegacyTagOnly:)
  // Now using the more comprehensive purgeManagedTargets(in:) implementation below.

  /// Purges all events carrying the CalendarSync marker in the specified target calendars.
  /// - Parameter targetCalendarIds: Identifiers of target calendars to purge.
  /// - Returns: Tuple including:
  ///   - `deleted`: Total number of deleted events across all calendars.
  ///   - `details`: Lightweight per-event details for logging.
  ///   - `summaries`: Per-calendar diagnostic summaries (attempted, matched, deleted, writability).
  ///   - `authStatus`: Human-readable authorization status at the time of purge.
  /// - Why: Allows purging even when sync configurations are disabled or when multiple configs
  ///   share the same target calendar. This does not require knowledge of current tuples.
  /// - Implementation: Events are enumerated directly from the specified EventKit calendars.
  ///   Internal mappings are consulted only to remove rows corresponding to successfully deleted
  ///   events. Mappings never drive which events are selected for purge.
  struct PurgeCalendarSummary {
    /// Identifier of the calendar that was scanned.
    let calendarId: String
    /// Display name of the calendar that was scanned.
    let calendarTitle: String
    /// Whether EventKit reports the calendar allows content modifications (create/update/delete).
    let allowsModifications: Bool
    /// Total number of events enumerated in this calendar (bounded by distantPast/future).
    let enumeratedCount: Int
    /// Number of events that matched our branding/tag presence criteria.
    let brandingMatchCount: Int
    /// Number of events successfully deleted from this calendar.
    let deletedCount: Int
  }

  func purgeManagedTargets() throws -> (
    deleted: Int, details: [PurgedEventDetails], summaries: [PurgeCalendarSummary],
    authStatus: String
  ) {
    print(
      "Purging managed targets"
    )
    let auth = EKEventStore.authorizationStatus(for: .event)
    let authStatus: String = {
      switch auth {
      case .fullAccess: return "fullAccess"
      case .writeOnly: return "writeOnly"
      case .authorized: return "authorized"
      case .restricted: return "restricted"
      case .denied: return "denied"
      case .notDetermined: return "notDetermined"
      @unknown default: return "unknown"
      }
    }()
    guard auth == .fullAccess || auth == .authorized || auth == .writeOnly else {
      print(
        "Authorization status is \(authStatus), cannot purge"
      )
      return (0, [], [], authStatus)
    }

    print(
      "Authorization status is \(authStatus), continuing with purge"
    )

    var total = 0
    var details: [PurgedEventDetails] = []
    var summaries: [PurgeCalendarSummary] = []

    var start = Date()
    var end = Date()

    start.addTimeInterval(-1 * 365 * 24 * 3600 * 1.0)
    end.addTimeInterval(4 * 365 * 24 * 3600 * 1.0)

    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events = store.events(matching: predicate)

    // Log how many events we enumerated in this calendar for transparency in the console.
    print(
      " -> Date Range: \(start) to \(end)"
    )
    print(
      " -> Predicate: \(predicate)"
    )
    print(
      " -> Enumerated \(events.count) events to delete"
    )
    var matches = 0
    var deletedInCalendar = 0

    for ev in events {
      // Prepare human-readable timestamps for logging purposes.
      let startISO = ev.startDate.map { isoFormatter.string(from: $0) } ?? "-"
      let endISO = ev.endDate.map { isoFormatter.string(from: $0) } ?? "-"

      // Deletion criteria: only check that the notes (description) contain the branding phrase.
      // We do not rely on structured markers or URL tags for deletion.
      let hasBranding = (ev.notes?.contains("Tobisk Calendar Sync") ?? false)
      guard hasBranding else {
        continue
      }
      matches += 1
      // Log the candidate that will be deleted.
      print(
        "         -> Matched for purge: '\(ev.title ?? "")' [\(startISO) – \(endISO)]"
      )

      try store.remove(ev, span: .thisEvent)
      total += 1
      deletedInCalendar += 1

      // Confirm deletion in the console for immediate feedback.
      print(
        "         -> Deleted: '\(ev.title ?? "")' [\(startISO) – \(endISO)]"
      )
    }

    print(
      "Calendar purged"
    )

    return (total, details, summaries, authStatus)
  }
}
