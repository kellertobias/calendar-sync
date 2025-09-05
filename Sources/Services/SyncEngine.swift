import Foundation
import EventKit
import SwiftData

/// Computes and applies one-way sync actions for a single configuration.
/// Supports Full and Blocker modes, filters, weekday/time windows, and tagging.
/// Computes and applies plans and persists event mappings.
/// Why: Using `SDEventMapping` as the source of truth prevents relying solely on fragile tag parsing.
@MainActor
final class SyncEngine {
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

    /// Initializes the engine with a SwiftData model context.
    /// - Parameter modelContext: Context used to read/write `SDEventMapping` and logs.
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Shared ISO-8601 formatter for stable per-occurrence keys.
    private lazy var isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Using internet date time ensures timezone and seconds; stable across runs.
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Builds stable components used to identify a specific occurrence of a source event.
    /// - Returns: `(sourceId, occISO, key)` where key is `tuple|sourceId|occISO`.
    /// - Why: Recurring events share an identifier; `occurrenceDate` disambiguates instances.
    /// - Note: For detached overrides, EventKit sets `occurrenceDate` to the original instance date,
    ///   which is what we want to ensure mappings remain stable even when an instance is edited.
    private func makeOccurrenceComponents(_ event: EKEvent, configId: UUID) -> (String, String, String) {
        let sourceId = event.eventIdentifier ?? UUID().uuidString
        let occDate = event.occurrenceDate ?? event.startDate ?? Date()
        let occISO = isoFormatter.string(from: occDate)
        let key = "\(configId.uuidString)|\(sourceId)|\(occISO)"
        return (sourceId, occISO, key)
    }

    /// Marker inserted on created/managed target events.
    private func marker(syncId: UUID, sourceId: String, occurrenceISO: String) -> String {
        "[CalendarSync] tuple=\(syncId.uuidString) source=\(sourceId) occ=\(occurrenceISO)"
    }

    private func extractMarker(from event: EKEvent) -> (tuple: String, source: String, occ: String)? {
        if let m = SyncRules.extractMarker(notes: event.notes, urlString: event.url?.absoluteString) {
            return (m.tuple, m.source, m.occ)
        }
        return nil
    }

    /// Builds a plan of changes between source and target within a horizon.
    /// Strategy:
    /// 1) Prefer mapping lookup (sourceId + occurrenceISO → targetIdentifier) to locate targets.
    /// 2) Fallback to tag parsing when mapping is missing (first run / recovery).
    /// 3) Only propose deletions for items we own (mapping + tag + calendar ownership).
    func buildPlan(config: SyncConfigUI, defaultHorizonDays: Int) -> PlanResult {
        // Require full access on macOS 14+ to avoid deprecation and ensure read capability.
        let auth = EKEventStore.authorizationStatus(for: .event)
        guard auth == .fullAccess else {
            return PlanResult(actions: [], created: 0, updated: 0, deleted: 0)
        }

        let horizon = TimeInterval((config.horizonDaysOverride ?? defaultHorizonDays) * 24 * 3600)
        let windowStart = Date()
        let windowEnd = Date().addingTimeInterval(horizon)

        guard let sourceCal = store.calendar(withIdentifier: config.sourceCalendarId),
              let targetCal = store.calendar(withIdentifier: config.targetCalendarId) else {
            return PlanResult(actions: [], created: 0, updated: 0, deleted: 0)
        }

        // Fetch occurrences
        let sourcePredicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [sourceCal])
        let targetPredicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [targetCal])
        let sourceEvents = store.events(matching: sourcePredicate)
        let targetEvents = store.events(matching: targetPredicate)

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

        // Index target by (tuple, sourceId, occ) via tags
        var taggedTargets: [String: EKEvent] = [:]
        for te in targetEvents {
            if let tag = extractMarker(from: te) {
                let key = "\(tag.tuple)|\(tag.source)|\(tag.occ)"
                taggedTargets[key] = te
            }
        }

        // Index target by (tuple, sourceId, occ) via mappings
        var mappedTargets: [String: EKEvent] = [:]
        for m in mappings {
            if let te = targetByIdentifier[m.targetEventIdentifier] {
                let key = "\(config.id.uuidString)|\(m.sourceEventIdentifier)|\(m.occurrenceDateKey)"
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
            // Status flags
            let status = ev.status
            let isConfirmed = status == .confirmed
            let isTentative = status == .tentative

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
                filters: config.filters,
                sourceNotes: ev.notes,
                sourceURLString: ev.url?.absoluteString,
                configId: config.id
            )
        }

        func allowedByTimeWindows(_ ev: EKEvent) -> Bool {
            SyncRules.allowedByTimeWindows(start: ev.startDate, isAllDay: ev.isAllDay, windows: config.timeWindows)
        }

        func contains(_ str: String, pattern: String, cs: Bool) -> Bool {
            cs ? str.contains(pattern) : str.range(of: pattern, options: [.caseInsensitive]) != nil
        }
        func regex(_ str: String, pattern: String, cs: Bool) -> Bool {
            guard let r = try? NSRegularExpression(pattern: pattern, options: cs ? [] : [.caseInsensitive]) else { return false }
            return r.firstMatch(in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length)) != nil
        }

        var actions: [PlanAction] = []
        var created = 0, updated = 0, deleted = 0

        // Build a set of valid keys from source to later detect deletions
        var liveKeys: Set<String> = []

        for se in sourceEvents {
            guard passesFilters(se), allowedByTimeWindows(se) else { continue }
            let (sourceId, occISO, key) = makeOccurrenceComponents(se, configId: config.id)
            liveKeys.insert(key)
            let teFromMapping = mappedTargets[key]
            let teFromTag = teFromMapping == nil ? taggedTargets[key] : nil
            if let te = teFromMapping ?? teFromTag {
                // If discovered only via tag, migrate to mapping for resilience
                if teFromMapping == nil, let targetId = te.eventIdentifier {
                    let exists = mappings.contains { $0.sourceEventIdentifier == sourceId && $0.occurrenceDateKey == occISO }
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
                    }
                }
                // Compare fields to see if update needed
                if needsUpdate(source: se, target: te, mode: config.mode, template: config.blockerTitleTemplate) {
                    actions.append(PlanAction(kind: .update, source: se, target: te, reason: "Fields changed"))
                    updated += 1
                }
            } else {
                actions.append(PlanAction(kind: .create, source: se, target: nil, reason: "Missing in target"))
                created += 1
            }
        }

        // Deletions: consider both mapped and tagged targets, but require ownership safety
        func hasMapping(for key: String) -> Bool { mappedTargets[key] != nil || mappings.contains { "\(config.id.uuidString)|\($0.sourceEventIdentifier)|\($0.occurrenceDateKey)" == key } }
        func safeToDelete(_ te: EKEvent, key: String) -> Bool {
            let marker = extractMarker(from: te).map { SyncRules.Marker(tuple: $0.tuple, source: $0.source, occ: $0.occ) }
            return SyncRules.safeToDeletePolicy(
                configId: config.id,
                targetCalendarId: config.targetCalendarId,
                eventCalendarId: te.calendar.calendarIdentifier,
                marker: marker,
                hasMapping: hasMapping(for: key)
            )
        }

        // From mappings
        for (key, te) in mappedTargets {
            if !liveKeys.contains(key) && safeToDelete(te, key: key) {
                actions.append(PlanAction(kind: .delete, source: nil, target: te, reason: "Source missing (mapped)"))
                deleted += 1
            }
        }
        // From tags that are not mapped (legacy)
        for te in targetEvents {
            guard let tag = extractMarker(from: te), tag.tuple == config.id.uuidString else { continue }
            let key = "\(tag.tuple)|\(tag.source)|\(tag.occ)"
            if mappedTargets[key] == nil && !liveKeys.contains(key) && safeToDelete(te, key: key) {
                actions.append(PlanAction(kind: .delete, source: nil, target: te, reason: "Source missing (tagged)"))
                deleted += 1
            }
        }

        return PlanResult(actions: actions, created: created, updated: updated, deleted: deleted)
    }

    private func needsUpdate(source: EKEvent, target: EKEvent, mode: SyncMode, template: String?) -> Bool {
        switch mode {
        case .full:
            return source.title != target.title || source.startDate != target.startDate || source.endDate != target.endDate || (source.location ?? "") != (target.location ?? "")
        case .blocker:
            let title = blockerTitle(from: source, template: template)
            return title != target.title || source.startDate != target.startDate || source.endDate != target.endDate
        }
    }

    private func blockerTitle(from source: EKEvent, template: String?) -> String {
        let t = template ?? "Busy"
        return t.replacingOccurrences(of: "{sourceTitle}", with: source.title ?? "")
    }

    /// Applies a plan directly to the target calendar. Requires authorization.
    func apply(config: SyncConfigUI, plan: PlanResult) throws {
        guard let targetCal = store.calendar(withIdentifier: config.targetCalendarId) else { return }
        for action in plan.actions {
            switch action.kind {
            case .create:
                guard let se = action.source else { continue }
                let ev = EKEvent(eventStore: store)
                ev.calendar = targetCal
                copy(from: se, to: ev, mode: config.mode, template: config.blockerTitleTemplate)
                let (sourceId, occISO, _) = makeOccurrenceComponents(se, configId: config.id)
                let tag = marker(syncId: config.id, sourceId: sourceId, occurrenceISO: occISO)
                ev.notes = [tag, se.notes ?? ""].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if ev.url == nil { ev.url = URL(string: tag) }
                try store.save(ev, span: .thisEvent)
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
                }
            case .update:
                guard let se = action.source, let te = action.target else { continue }
                copy(from: se, to: te, mode: config.mode, template: config.blockerTitleTemplate)
                try store.save(te, span: .thisEvent)
                // Upsert mapping on update in case identifiers rotated
                if let targetId = te.eventIdentifier {
                    let (sourceId, occISO, _) = makeOccurrenceComponents(se, configId: config.id)
                    let fetch = FetchDescriptor<SDEventMapping>(predicate: #Predicate {
                        $0.syncConfigId == config.id &&
                        $0.sourceEventIdentifier == sourceId &&
                        $0.occurrenceDateKey == occISO
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
                    // Best-effort cleanup of mapping for this target id
                    if let targetId = te.eventIdentifier {
                        let fetch = FetchDescriptor<SDEventMapping>(predicate: #Predicate {
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
        case .full:
            target.title = source.title
            target.location = source.location
        case .blocker:
            target.title = blockerTitle(from: source, template: template)
            target.location = nil
        }
        target.availability = .busy
    }
}


