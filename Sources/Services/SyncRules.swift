import Foundation

/// Pure helper functions for evaluating filters, time windows, and tag markers.
/// Why: Extracted from the sync engine to enable deterministic unit testing without EventKit.
enum SyncRules {
  /// Shared ISO-8601 formatter for stable per-occurrence keys.
  /// - Important: Time zone is forced to UTC to ensure keys are consistent across devices
  ///   regardless of local time zone settings and daylight saving changes.
  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
  }()
  /// Parsed marker metadata embedded by CalendarSync into event notes or URL.
  /// - tuple: Optional legacy/current tuple/config identifier. Present when available.
  /// - name: Optional URL-encoded sync name for cross-device matching when tuple differs.
  /// - source: Source event identifier from the provider (EventKit's `eventIdentifier`).
  /// - occ: ISO-8601 string of the instance's `occurrenceDate` to disambiguate recurrences.
  /// - key: Optional stable sync key `<sync-id>-<hash>` introduced to avoid per-device IDs.
  struct Marker: Equatable {
    let tuple: String?
    let name: String?
    let source: String?
    let occ: String?
    let key: String?
  }

  /// Builds stable components used to identify a specific occurrence of a source event.
  /// - Parameters:
  ///   - sourceId: The EventKit event identifier.
  ///   - occurrenceDate: The `occurrenceDate` of the instance (preferred when present).
  ///   - startDate: Fallback when `occurrenceDate` is `nil`.
  /// - Returns: `(sourceId, occISO, key)` where key is `sourceId|occISO`.
  static func occurrenceComponents(
    sourceId: String, occurrenceDate: Date?, startDate: Date?
  ) -> (String, String, String) {
    let occ = occurrenceDate ?? startDate ?? Date()
    let occISO = isoFormatter.string(from: occ)
    let key = "\(sourceId)|\(occISO)"
    return (sourceId, occISO, key)
  }

  /// Determines whether two events differ in fields relevant to the selected sync mode.
  /// - Note: Blocker mode compares computed blocker title and time; location is ignored.
  static func needsUpdate(
    mode: SyncMode, template: String?, sourceTitle: String?, targetTitle: String?,
    sourceStart: Date?, targetStart: Date?, sourceEnd: Date?, targetEnd: Date?,
    sourceLocation: String?, targetLocation: String?
  ) -> Bool {
    switch mode {
    case .full, .privateEvents:
      return sourceTitle != targetTitle || sourceStart != targetStart || sourceEnd != targetEnd
        || (sourceLocation ?? "") != (targetLocation ?? "")
    case .blocker:
      let t = (template ?? "Busy").replacingOccurrences(
        of: "{sourceTitle}", with: sourceTitle ?? "")
      return t != (targetTitle ?? "") || sourceStart != targetStart || sourceEnd != targetEnd
    }
  }

  /// Extracts our embedded marker from notes or URL strings.
  /// - Returns: Marker components if present. Accepts key-only markers.
  static func extractMarker(notes: String?, urlString: String?) -> Marker? {
    let candidates: [String] = [notes ?? "", urlString ?? ""]
    for c in candidates where !c.isEmpty {
      if let range = c.range(of: "[CalendarSync]") {
        let tail = c[range.lowerBound...]
        // Tokenize by spaces; each token should be either the literal tag token or key=value pairs.
        // Values can themselves contain '=' (e.g., "/RID=12345"). Therefore, split each token
        // on the FIRST '=' only to preserve the remainder as the value.
        let comps = tail.split(separator: " ")
        var dict: [String: String] = [:]
        for kv in comps {
          guard let eqIdx = kv.firstIndex(of: "=") else { continue }
          let key = String(kv[..<eqIdx])
          let valueStart = kv.index(after: eqIdx)
          let value = String(kv[valueStart...])
          dict[key] = value
        }
        // Accept when any of the known fields are present; allow key-only markers.
        let t = dict["tuple"]
        let n = dict["name"]
        let s = dict["source"]
        let o = dict["occ"]
        let k = dict["key"]
        if t != nil || n != nil || s != nil || o != nil || k != nil {
          return Marker(tuple: t, name: n, source: s, occ: o, key: k)
        }
      }
    }
    return nil
  }

  /// Evaluates an event snapshot against configured filter rules.
  /// - Parameters:
  ///   - title: Event title (empty allowed).
  ///   - location: Event location (optional).
  ///   - notes: Event notes/description (optional).
  ///   - organizer: Organizer display name or URL/email (optional).
  ///   - attendees: Attendee display names or emails. Defaults to empty list.
  ///   - durationMinutes: Event duration in minutes (rounded down). Defaults to `nil` when start/end missing.
  ///   - isAllDay: Whether the event is marked as all-day. Defaults to `false`.
  ///   - isStatusConfirmed: Whether the event status is confirmed/accepted. Defaults to `false`.
  ///   - isStatusTentative: Whether the event status is tentative/maybe. Defaults to `false`.
  ///   - filters: Filter rules to apply.
  ///   - sourceNotes: Notes of the source event (to detect existing tuple markers).
  ///   - sourceURLString: URL string of the source event (alternative marker location).
  ///   - configId: Current tuple id; used by `ignoreOtherTuples`.
  static func passesFilters(
    title: String,
    location: String?,
    notes: String?,
    organizer: String?,
    attendees: [String] = [],
    durationMinutes: Int? = nil,
    isAllDay: Bool = false,
    isStatusConfirmed: Bool = false,
    isStatusTentative: Bool = false,
    attendeesCount: Int = 0,
    isRepeating: Bool = false,
    isAvailabilityBusy: Bool = true,
    filters: [FilterRuleUI],
    sourceNotes: String?,
    sourceURLString: String?,
    configId: UUID
  ) -> Bool {
    let titleValue = title
    let locationValue = location ?? ""
    let notesValue = notes ?? ""
    let organizerValue = organizer ?? ""
    let attendeeValues = attendees
    for rule in filters {
      switch rule.type {
      case .includeTitle:
        if !contains(titleValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeTitle:
        if contains(titleValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .includeRegex:
        if !regex(titleValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeRegex:
        if regex(titleValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }

      case .includeLocation:
        if !contains(locationValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeLocation:
        if contains(locationValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .includeLocationRegex:
        if !regex(locationValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeLocationRegex:
        if regex(locationValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }

      case .includeNotes:
        if !contains(notesValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeNotes:
        if contains(notesValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .includeNotesRegex:
        if !regex(notesValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeNotesRegex:
        if regex(notesValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }

      case .includeOrganizer:
        if !contains(organizerValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeOrganizer:
        if contains(organizerValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .includeOrganizerRegex:
        if !regex(organizerValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }
      case .excludeOrganizerRegex:
        if regex(organizerValue, pattern: rule.pattern, cs: rule.caseSensitive) { return false }

      case .includeAttendee:
        // Require at least one attendee to contain the pattern
        if !attendeeValues.contains(where: {
          contains($0, pattern: rule.pattern, cs: rule.caseSensitive)
        }) {
          return false
        }
      case .excludeAttendee:
        // Exclude if any attendee contains the pattern
        if attendeeValues.contains(where: {
          contains($0, pattern: rule.pattern, cs: rule.caseSensitive)
        }) {
          return false
        }

      case .durationLongerThan:
        if let mins = durationMinutes,
          let threshold = Int(rule.pattern.trimmingCharacters(in: .whitespaces))
        {
          if mins <= threshold { return false }
        }
      case .durationShorterThan:
        if let mins = durationMinutes,
          let threshold = Int(rule.pattern.trimmingCharacters(in: .whitespaces))
        {
          if mins >= threshold { return false }
        }

      case .includeAllDay:
        if !isAllDay { return false }
      case .excludeAllDay:
        if isAllDay { return false }
      case .excludeAllDayWhenFree:
        // Exclude only when the event is all-day and marked as free availability.
        // Why: All-day reminders often should not create blockers; keep truly busy all-day events.
        if isAllDay && !isAvailabilityBusy { return false }

      case .onlyAccepted, .acceptedOrMaybe, .acceptedOrTentative:
        // Deprecated: ignore status-based filtering
        break

      case .attendeesCountAbove:
        if let threshold = Int(rule.pattern.trimmingCharacters(in: .whitespaces)) {
          if attendeesCount <= threshold { return false }
        }
      case .attendeesCountBelow:
        if let threshold = Int(rule.pattern.trimmingCharacters(in: .whitespaces)) {
          if attendeesCount >= threshold { return false }
        }

      case .isRepeating:
        if !isRepeating { return false }
      case .isNotRepeating:
        if isRepeating { return false }

      case .availabilityBusy:
        if !isAvailabilityBusy { return false }
      case .availabilityFree:
        if isAvailabilityBusy { return false }

      case .ignoreOtherTuples:
        // Ignore events that were created by CalendarSync itself, identified by a descriptive note marker.
        // Why: Users expect not to resync or duplicate already-synced/created events.
        // Behavior change: Instead of tuple-based exclusion, treat any event whose description
        // contains the human-readable phrase as a synced event and exclude it.
        let notesValueLowercased = (sourceNotes ?? notes ?? "").lowercased()
        if notesValueLowercased.contains("tobisk calendar sync".lowercased()) {
          return false
        }
      }
    }
    return true
  }

  /// Determines whether an event start falls within any configured windows.
  /// - Note: Windows are evaluated on the event start's weekday. Range is [start, end).
  static func allowedByTimeWindows(start: Date?, isAllDay: Bool = false, windows: [TimeWindowUI])
    -> Bool
  {
    if windows.isEmpty { return true }
    // Policy: when windows are defined, exclude all-day events unless explicitly allowed via a specialized rule (not yet implemented).
    if isAllDay { return false }
    guard let start else { return false }
    let cal = Calendar.current
    let weekdayIdx = cal.component(.weekday, from: start)  // 1=Sun...7=Sat
    let map: [Int: Weekday] = [
      1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday, 5: .thursday, 6: .friday, 7: .saturday,
    ]
    guard let wd = map[weekdayIdx] else { return false }
    for tw in windows where tw.weekday == wd {
      let s = tw.start.asDate(anchor: start)
      let e = tw.end.asDate(anchor: start)
      if start >= s && start < e { return true }
    }
    return false
  }

  /// Deletion safety policy: no longer used for tuple/name matching. Retained for back-compat callers.
  static func safeToDeletePolicy(
    targetCalendarId: String,
    eventCalendarId: String,
    marker: Marker?,
    expectedTupleId: UUID,
    expectedEncodedName: String
  ) -> Bool {
    // Legacy behavior removed: only calendar equality remains relevant here; ownership by key is
    // enforced by callers using the `key` prefix match.
    guard eventCalendarId == targetCalendarId, let _ = marker else { return false }
    return true
  }

  private static func contains(_ str: String, pattern: String, cs: Bool) -> Bool {
    cs ? str.contains(pattern) : str.range(of: pattern, options: [.caseInsensitive]) != nil
  }
  private static func regex(_ str: String, pattern: String, cs: Bool) -> Bool {
    guard let r = try? NSRegularExpression(pattern: pattern, options: cs ? [] : [.caseInsensitive])
    else { return false }
    return r.firstMatch(
      in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length)) != nil
  }
}
