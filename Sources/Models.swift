import Foundation

/// Identifies the mode used to mirror data from the source calendar into the target.
/// - full: Copies title, notes, attendees, location, and time details.
/// - privateEvents: Copies full details but intends the target to be private so others only see
///   free/busy. Why: Preserve local fidelity while hiding details in shared views.
///   Note: EventKit does not expose a universal cross-provider privacy flag. The engine always
///   sets availability to `.busy`. Some providers may still show details depending on account
///   permissions and server-side privacy capabilities.
/// - blocker: Creates opaque blocking events with a template title.
enum SyncMode: String, Codable, CaseIterable, Identifiable {
  case full
  case privateEvents
  case blocker

  var id: String { rawValue }
}

/// UI-facing model representing a configured sync tuple.
/// Why: Keep the UI decoupled from persistence (SwiftData) and EventKit specifics.
struct SyncConfigUI: Identifiable, Hashable, Codable {
  var id: UUID = UUID()
  var name: String
  var sourceCalendarId: String
  var targetCalendarId: String
  var mode: SyncMode
  var blockerTitleTemplate: String?
  var horizonDaysOverride: Int?
  var enabled: Bool
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var filters: [FilterRuleUI] = []
  var timeWindows: [TimeWindowUI] = []
}

/// Represents a simple last run status summary for display in the menu.
struct LastRunStatus: Codable, Hashable {
  var lastSuccessAt: Date?
  var lastFailureAt: Date?
  var lastMessage: String?
}

/// Represents a calendar option for selection in the UI.
struct CalendarOption: Identifiable, Hashable, Codable {
  var id: String
  var name: String
  /// Human-readable account/source name (e.g., "iCloud", "Gmail", or account email).
  /// Why: Used to group calendars in pickers by their owning account for clearer selection.
  var account: String
  var isWritable: Bool
  /// sRGB hex like "#RRGGBB" for display-only coloring in pickers.
  var colorHex: String?
}

/// Supported filter rule types for the UI.
enum FilterRuleType: String, Codable, CaseIterable, Identifiable {
  case includeTitle
  case excludeTitle
  case includeRegex
  case excludeRegex

  case includeLocation
  case excludeLocation
  case includeLocationRegex
  case excludeLocationRegex

  case includeNotes
  case excludeNotes
  case includeNotesRegex
  case excludeNotesRegex

  case includeOrganizer
  case excludeOrganizer
  case includeOrganizerRegex
  case excludeOrganizerRegex

  // Attendees (names or emails)
  case includeAttendee
  case excludeAttendee

  // Duration thresholds (minutes)
  case durationLongerThan
  case durationShorterThan

  // All-day include/exclude
  case includeAllDay
  case excludeAllDay
  /// Exclude all-day events that are explicitly marked as Free in availability.
  /// Why: Many users create all-day reminders that should not block their time. This rule
  /// provides a precise way to drop those without excluding truly busy all-day blocks.
  case excludeAllDayWhenFree

  // Event status (source event status) — deprecated, retained for backwards compatibility
  case onlyAccepted
  case acceptedOrMaybe
  case acceptedOrTentative

  // Attendee count comparisons
  case attendeesCountAbove
  case attendeesCountBelow

  // Repeating status
  case isRepeating
  case isNotRepeating

  // Availability (busy/free)
  case availabilityBusy
  case availabilityFree

  case ignoreOtherTuples

  var id: String { rawValue }
  var label: String {
    switch self {
    case .includeTitle: return "Include title contains"
    case .excludeTitle: return "Exclude title contains"
    case .includeRegex: return "Include title regex"
    case .excludeRegex: return "Exclude title regex"

    case .includeLocation: return "Include location contains"
    case .excludeLocation: return "Exclude location contains"
    case .includeLocationRegex: return "Include location regex"
    case .excludeLocationRegex: return "Exclude location regex"

    case .includeNotes: return "Include notes contains"
    case .excludeNotes: return "Exclude notes contains"
    case .includeNotesRegex: return "Include notes regex"
    case .excludeNotesRegex: return "Exclude notes regex"

    case .includeOrganizer: return "Include organizer contains"
    case .excludeOrganizer: return "Exclude organizer contains"
    case .includeOrganizerRegex: return "Include organizer regex"
    case .excludeOrganizerRegex: return "Exclude organizer regex"

    case .includeAttendee: return "Include attendee contains"
    case .excludeAttendee: return "Exclude attendee contains"

    case .durationLongerThan: return "Duration longer than (minutes)"
    case .durationShorterThan: return "Duration shorter than (minutes)"

    case .includeAllDay: return "Include all-day events"
    case .excludeAllDay: return "Exclude all-day events"
    case .excludeAllDayWhenFree: return "Exclude all-day events when free"

    case .onlyAccepted: return "(deprecated) Only accepted"
    case .acceptedOrMaybe: return "(deprecated) Accepted or Tentative"
    case .acceptedOrTentative: return "(deprecated) Accepted or Tentative"

    case .attendeesCountAbove: return "Attendees count above"
    case .attendeesCountBelow: return "Attendees count below"

    case .isRepeating: return "Is a repeating event"
    case .isNotRepeating: return "Is not a repeating event"

    case .availabilityBusy: return "Availability is busy"
    case .availabilityFree: return "Availability is free"

    case .ignoreOtherTuples: return "Ignore Synced Events"
    }
  }
}

/// UI filter rule model.
struct FilterRuleUI: Identifiable, Codable, Hashable {
  var id: UUID = UUID()
  var type: FilterRuleType
  var pattern: String = ""
  var caseSensitive: Bool = false
}

/// Days of the week for time window policies.
enum Weekday: String, Codable, CaseIterable, Identifiable {
  case monday, tuesday, wednesday, thursday, friday, saturday, sunday
  var id: String { rawValue }
  var label: String {
    switch self {
    case .monday: return "Mon"
    case .tuesday: return "Tue"
    case .wednesday: return "Wed"
    case .thursday: return "Thu"
    case .friday: return "Fri"
    case .saturday: return "Sat"
    case .sunday: return "Sun"
    }
  }
}

/// Simple time of day without a date.
struct TimeOfDay: Codable, Hashable {
  var hour: Int
  var minute: Int

  static let `default` = TimeOfDay(hour: 9, minute: 0)

  func asDate(anchor: Date = Date()) -> Date {
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: anchor)
    comps.hour = hour
    comps.minute = minute
    return cal.date(from: comps) ?? anchor
  }

  static func from(date: Date) -> TimeOfDay {
    let cal = Calendar.current
    let comps = cal.dateComponents([.hour, .minute], from: date)
    return TimeOfDay(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
  }
}

/// A weekday-specific time window.
struct TimeWindowUI: Identifiable, Codable, Hashable {
  var id: UUID = UUID()
  var weekday: Weekday
  var start: TimeOfDay
  var end: TimeOfDay
}
