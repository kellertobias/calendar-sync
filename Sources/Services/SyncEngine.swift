import EventKit
import Foundation
import OSLog
import SwiftData
import CryptoKit

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
  private let reminderStore = EKEventStore()
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

  /// Computes a stable sync key from the sync name and the source event's
  /// title combined with the UTC-normalized occurrence start.
  /// - Format: "<sha256(syncName)>-<sha256(title|occISO)>" (lowercase hex)
  /// - Why: Avoids relying on provider-specific identifiers that differ across devices.
  private func computeSyncKey(syncName: String, title: String?, occISO: String) -> String {
    // Namespace is a SHA-256 of the sync name. It prefixes the key and establishes ownership.
    // Why: Multiple syncs may share a target calendar. Keys must be partitioned per-sync so that
    // one sync never cleans up items created by another. We enforce this by checking the prefix.
    let ns = SHA256.hash(data: Data(syncName.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    let basis = (title ?? "") + "|" + occISO
    let digest = SHA256.hash(data: Data(basis.utf8))
    let hashHex = digest.compactMap { String(format: "%02x", $0) }.joined()
    return "\(ns)-\(hashHex)"
  }

  /// Computes the stable namespace prefix used in `key` for a given sync configuration name.
  /// - Important: This prefix MUST be used to assert ownership when considering deletions,
  ///   ensuring normal sync runs never remove items produced by other syncs.
  private func computeSyncNamespace(syncName: String) -> String {
    SHA256.hash(data: Data(syncName.utf8)).compactMap { String(format: "%02x", $0) }.joined()
  }

  /// Builds stable components used to identify a specific occurrence of a source event.
  /// - Important:
  ///   - EventKit's `eventIdentifier` can differ across devices and can rotate.
  ///   - We mitigate this by combining the identifier with a UTC-normalized occurrence timestamp.
  ///   - This makes keys stable for recurring events across computers when internal state is cleared.
  /// - Returns: `(sourceId, occISO, key)` where key is `sourceId|occISO`.
  /// - Why: Recurring events share an identifier; `occurrenceDate` disambiguates instances.
  /// - Note: For detached overrides, EventKit sets `occurrenceDate` to the original instance date,
  ///   which is what we want to ensure mappings remain stable even when an instance is edited.
  private func makeOccurrenceComponents(_ event: EKEvent) -> (
    String, String, String
  ) {
    // Identifier selection policy:
    // - macOS EventKit does not expose an externalIdentifier for events like iOS can in some contexts.
    // - Use `eventIdentifier` when available; otherwise, fall back to a synthesized, deterministic ID
    //   derived from salient immutable fields so we do not create a new UUID each pass.
    // - This fallback helps when source events are produced from read-only feeds that do not expose IDs.
    let sourceId: String = {
      if let id = event.eventIdentifier, !id.isEmpty { return id }
      // Deterministic synthesized id: title|start|end in UTC
      let title = event.title ?? ""
      let s = event.startDate.map { isoFormatter.string(from: $0) } ?? "-"
      let e = event.endDate.map { isoFormatter.string(from: $0) } ?? "-"
      return "syn:" + title + "|" + s + "|" + e
    }()
    let occDate = event.occurrenceDate ?? event.startDate ?? Date()
    let occISO = isoFormatter.string(from: occDate)
    let key = "\(sourceId)|\(occISO)"
    return (sourceId, occISO, key)
  }

  /// Marker inserted on created/managed target events.
  /// - Format: "[CalendarSync] key=<nameHash>-<contentHash>"
  /// - Note: Only the key is emitted to avoid leaking identifiers.
  private func marker(key: String) -> String {
    return "[CalendarSync] key=\(key)"
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

  private func brandedMarkerBlock(key: String) -> String {
    let tag = marker(key: key)
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

    // Index target by stable key when present (new scheme) and legacy composite key
    var keyTargets: [String: EKEvent] = [:]
    var taggedTargets: [String: EKEvent] = [:]
    for te in targetEvents {
      if let tag = extractMarker(from: te) {
        if let k = tag.key {
          if keyTargets[k] != nil {
            print("[KeyDup] Duplicate key-tagged target key=\(k) title=\(te.title ?? "-")")
          }
          keyTargets[k] = te
        }
        let legacyKey = "\(tag.source)|\(tag.occ)"
        if taggedTargets[legacyKey] != nil {
          print("[TagDup] Duplicate tagged target for key=\(legacyKey) title=\(te.title ?? "-")")
        }
        taggedTargets[legacyKey] = te
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
    // - liveLegacyKeys: composite source|occ keys that pass filters (legacy)
    // - allLegacyKeys: all composite keys regardless of filters (safety net to avoid churn)
    // - liveSyncKeys: new stable keys <sync-id>-<hash(title|occISO)>
    var liveLegacyKeys: Set<String> = []
    var allLegacyKeys: Set<String> = []
    var liveSyncKeys: Set<String> = []

    // Track duplicates from source enumeration within a single build pass.
    var seenSourceKeys: Set<String> = []

    // Index targets by (title, startDate) for loose matching
    // Only include targets that have the sync tag ("Tobisk Calendar Sync")
    // Values are arrays because there could theoretically be duplicates
    var looseTargetIndex: [String: [EKEvent]] = [:]
    for te in targetEvents {
      // Check for sync tag
      guard (te.notes?.contains("Tobisk Calendar Sync") == true) else { continue }
      
      let title = te.title ?? ""
      let start = te.startDate.map { isoFormatter.string(from: $0) } ?? "-"
      let key = "\(title)|\(start)"
      looseTargetIndex[key, default: []].append(te)
    }

    for se in sourceEvents {
      let (sid0, occ0, rawKey) = makeOccurrenceComponents(se)
      allLegacyKeys.insert(rawKey)
      // Detect and skip duplicates within the same planning window.
      if seenSourceKeys.contains(rawKey) {
        print(
          "[SrcDup] Duplicate source occurrence key=\(rawKey) title=\(se.title ?? "-") occ=\(occ0) sid=\(sid0)"
        )
        continue
      }
      seenSourceKeys.insert(rawKey)

      guard passesFilters(se), allowedByTimeWindows(se) else { continue }
      let (sourceId, occISO, legacyKey) = makeOccurrenceComponents(se)
      liveLegacyKeys.insert(legacyKey)
      let syncKey = computeSyncKey(syncName: config.name, title: se.title, occISO: occISO)
      liveSyncKeys.insert(syncKey)
      
      // Try to find target by key first
      var te = keyTargets[syncKey]
      
      // Fallback: Loose matching (title + time + sync tag)
      // If we don't have a direct key match, look for a "orphaned" matching event
      if te == nil {
        let title = se.title ?? ""
        let start = se.startDate.map { isoFormatter.string(from: $0) } ?? "-"
        let key = "\(title)|\(start)"
        if let candidates = looseTargetIndex[key], let firstMatch = candidates.first {
           te = firstMatch
           print("[Plan] Loose match found for title=\(title) start=\(start). Treating as update candidate.")
        }
      }
      
      if let te = te {
        // Compare fields to see if update needed
        if needsUpdate(
          source: se, target: te, mode: config.mode, template: config.blockerTitleTemplate)
        {
          actions.append(
            PlanAction(kind: .update, source: se, target: te, reason: "Fields changed"))
          updated += 1
          print("[Plan] UPDATE key=\(syncKey) title=\(se.title ?? "-") start=\(se.startDate?.description ?? "-")")
        } else {
          print("[Plan] MATCH key=\(syncKey) title=\(se.title ?? "-") (no change)")
        }
      } else {
        actions.append(
          PlanAction(kind: .create, source: se, target: nil, reason: "Missing in target"))
        created += 1
        print("[Plan] CREATE key=\(syncKey) title=\(se.title ?? "-") start=\(se.startDate?.description ?? "-")")
      }
    }

    // Deletions: only consider key-tagged targets that are OWNED by this sync's namespace.
    // Why: Prevents removing items created by other syncs that share the same target calendar.
    func safeToDelete(_ te: EKEvent, key: String) -> Bool {
      // Must be in the configured target calendar.
      guard te.calendar.calendarIdentifier == config.targetCalendarId else { return false }
      // Ownership: key must start with this sync's namespace prefix.
      let ns = computeSyncNamespace(syncName: config.name)
      return key.hasPrefix(ns + "-")
    }
    // Key-only deletion with namespace ownership check
    for te in targetEvents {
      guard let m = extractMarker(from: te), let k = m.key else { continue }
      guard safeToDelete(te, key: k) else { continue }
      if !liveSyncKeys.contains(k) {
        actions.append(PlanAction(kind: .delete, source: nil, target: te, reason: "Source missing (key)"))
        deleted += 1
        print("[Plan] DELETE (key) key=\(k) title=\(te.title ?? "-")")
      }
    }

    // Sort actions: Deletions first
    actions.sort { a1, a2 in
      if a1.kind == .delete && a2.kind != .delete { return true }
      if a1.kind != .delete && a2.kind == .delete { return false }
      return false // Keep original order for same types
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
        let syncKey = computeSyncKey(syncName: config.name, title: se.title, occISO: occISO)
        let tag = marker(key: syncKey)
        let brandBlock = brandedMarkerBlock(key: syncKey)
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
          let (_, occISO, _) = makeOccurrenceComponents(se)
          let syncKey = computeSyncKey(syncName: config.name, title: se.title, occISO: occISO)
          let tag = marker(key: syncKey)
          let brandBlock = brandedMarkerBlock(key: syncKey)
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
    let details: [PurgedEventDetails] = []
    let summaries: [PurgeCalendarSummary] = []

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

  /// Fetches tasks/reminders from all calendars within the specified time horizon.
  /// Only includes tasks that are not marked as completed AND have a due date assigned.
  /// - Parameters:
  ///   - horizonDays: Number of days to look ahead and behind from current date
  /// - Returns: Array of task data suitable for sending to external systems
  func fetchTasks(horizonDays: Int) async -> [TaskData] {
    // Check authorization for reminders
    let auth = EKEventStore.authorizationStatus(for: .reminder)
    guard auth == .fullAccess || auth == .authorized else {
      print("[Tasks] Authorization status is \(auth), cannot fetch tasks")
      return []
    }

    let horizon = TimeInterval(horizonDays * 24 * 3600)
    let windowStart = Date().addingTimeInterval(-horizon)  // Include past tasks
    let windowEnd = Date().addingTimeInterval(horizon)  // Include future tasks

    print("[Tasks] Fetching tasks from \(windowStart) to \(windowEnd)")

    // Fetch all reminders
    let predicate = reminderStore.predicateForReminders(in: nil)

    return await withCheckedContinuation { continuation in
      reminderStore.fetchReminders(matching: predicate) { reminders in
        guard let reminders = reminders else {
          print("[Tasks] Failed to fetch reminders")
          continuation.resume(returning: [])
          return
        }

        print("[Tasks] Found \(reminders.count) total reminders")
        var tasks: [TaskData] = []

        for reminder in reminders {
          // Skip completed tasks
          guard !reminder.isCompleted else {
            continue
          }

          // Only include tasks that have a due date assigned
          guard let dueDateComponents = reminder.dueDateComponents else {
            continue
          }

          // Convert due date components to Date object
          let calendar = Calendar.current
          guard let dueDateObj = calendar.date(from: dueDateComponents) else {
            continue
          }

          // Skip if due date is outside our horizon
          if dueDateObj < windowStart || dueDateObj > windowEnd {
            continue
          }

          // Create task data
          let task = TaskData(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled Task",
            notes: reminder.notes,
            dueDate: dueDateObj,
            priority: reminder.priority,
            completed: reminder.isCompleted,
            calendarTitle: reminder.calendar?.title ?? "Unknown Calendar",
            calendarId: reminder.calendar?.calendarIdentifier ?? ""
          )
          tasks.append(task)
          print("[Tasks] Added task: \(task.title) due \(task.dueDate ?? Date())")
        }

        print("[Tasks] Returning \(tasks.count) tasks")
        continuation.resume(returning: tasks)
      }
    }
  }
}

/// Represents a task/reminder for external system integration.
struct TaskData: Codable {
  /// Unique identifier of the task
  let id: String
  /// Title of the task
  let title: String
  /// Notes/description of the task
  let notes: String?
  /// Due date of the task (nil if no due date)
  let dueDate: Date?
  /// Priority level (0-9, where 0 is highest priority)
  let priority: Int
  /// Whether the task is completed
  let completed: Bool
  /// Name of the calendar this task belongs to
  let calendarTitle: String
  /// Identifier of the calendar this task belongs to
  let calendarId: String
}
