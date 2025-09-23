import EventKit
import Foundation

/// Pure helpers to evaluate invitation rules against EventKit events.
/// Why: Keep decision logic separate from UI and coordinator orchestration.
enum InvitationRules {
  /// Determine if an event is an invitation pending the current user's response.
  /// - Returns: true when the current user appears as an attendee with `.pending` status.
  static func isPendingInvitation(_ ev: EKEvent) -> Bool {
    guard let attendees = ev.attendees else { return false }
    guard let mine = attendees.first(where: { $0.isCurrentUser }) else { return false }
    return mine.participantStatus == .pending
  }

  /// Checks whether the invitation event passes the provided filter rules.
  static func passesInvitationFilters(_ ev: EKEvent, filters: [FilterRuleUI], configId: UUID)
    -> Bool
  {
    let organizerName = ev.organizer?.name ?? ev.organizer?.url.absoluteString ?? ""
    let attendeeNames: [String] = (ev.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString }
    let durationMins: Int? = {
      guard let s = ev.startDate, let e = ev.endDate else { return nil }
      return Int(e.timeIntervalSince(s) / 60)
    }()
    let isAllDay = ev.isAllDay
    // Derive RSVP status flags similar to SyncEngine
    let selfParticipantStatus: EKParticipantStatus? = (ev.attendees ?? []).first(where: {
      $0.isCurrentUser
    })?.participantStatus
    let isStatusConfirmed: Bool
    let isStatusTentative: Bool
    if let s = selfParticipantStatus {
      isStatusConfirmed = s == .accepted
      isStatusTentative = s == .tentative
    } else {
      let availabilityTentative = ev.availability == .tentative
      switch ev.status {
      case .confirmed:
        isStatusConfirmed = !availabilityTentative
        isStatusTentative = availabilityTentative
      case .tentative:
        isStatusConfirmed = false
        isStatusTentative = true
      default:
        isStatusConfirmed = false
        isStatusTentative = availabilityTentative
      }
    }
    let isAvailabilityBusy: Bool = {
      switch ev.availability { case .free: return false; default: return true }
    }()

    return SyncRules.passesFilters(
      title: ev.title ?? "",
      location: ev.location,
      notes: ev.notes,
      organizer: organizerName,
      attendees: attendeeNames,
      durationMinutes: durationMins,
      isAllDay: isAllDay,
      isStatusConfirmed: isStatusConfirmed,
      isStatusTentative: isStatusTentative,
      attendeesCount: ev.attendees?.count ?? 0,
      isRepeating: ev.hasRecurrenceRules,
      isAvailabilityBusy: isAvailabilityBusy,
      filters: filters,
      sourceNotes: ev.notes,
      sourceURLString: ev.url?.absoluteString,
      configId: configId
    )
  }

  /// Checks whether any existing events overlapping the invitation satisfy the overlap filters.
  /// - Parameters:
  ///   - store: EKEventStore to query.
  ///   - ev: The invitation event.
  ///   - calendars: The calendars to search for overlaps. Pass nil to search all.
  ///   - filters: Filters that must all pass on at least one overlapping event.
  static func hasQualifyingOverlap(
    store: EKEventStore,
    ev: EKEvent,
    calendars: [EKCalendar]?,
    filters: [FilterRuleUI],
    configId: UUID
  ) -> Bool {
    guard let start = ev.startDate, let end = ev.endDate else { return false }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    let overlapping = store.events(matching: predicate)
    guard !overlapping.isEmpty else { return false }
    for o in overlapping {
      if passesInvitationFilters(o, filters: filters, configId: configId) {
        return true
      }
    }
    return false
  }

  /// Returns whether the event is allowed by the provided time windows.
  static func allowedByWindows(_ ev: EKEvent, windows: [TimeWindowUI]) -> Bool {
    return SyncRules.allowedByTimeWindows(start: ev.startDate, isAllDay: ev.isAllDay, windows: windows)
  }
}


