import EventKit
import Foundation
import OSLog

/// Engine for calculating effective "CapEx" (Activatable Hours).
/// Approaches:
/// 1. Start with "Working Time" events as the base set of available time slots.
/// 2. Subtract time slots occupied by events in "Exclusion" calendars (matching specific rules).
@MainActor
final class CapExEngine {
  struct DateRange: Equatable {
    let start: Date
    let end: Date
    
    var duration: TimeInterval { end.timeIntervalSince(start) }
  }

  struct CalculationResult {
    let range: DateRange
    let totalWorkingSeconds: TimeInterval
    let totalExcludedSeconds: TimeInterval
    let netCapExSeconds: TimeInterval
    /// Daily breakdown
    let dailyStats: [Date: DailyStat]
  }

  struct DailyStat {
    let date: Date
    var workingSeconds: TimeInterval = 0
    var excludedSeconds: TimeInterval = 0
    var netSeconds: TimeInterval = 0
  }

  private let store = EKEventStore()
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "CapEx")

  /// Calculates the CapEx for a given time range and configuration.
  func calculate(config: CapExConfigUI, start: Date, end: Date) async -> CalculationResult {
    // 0. Permission check
    let auth = EKEventStore.authorizationStatus(for: .event)
    guard auth == .fullAccess || auth == .authorized else {
      logger.error("CapEx calculation failed: No calendar access.")
      return CalculationResult(
        range: DateRange(start: start, end: end),
        totalWorkingSeconds: 0, totalExcludedSeconds: 0, netCapExSeconds: 0, dailyStats: [:])
    }

    // 1. Fetch Working Time Events
    guard let workingCal = store.calendar(withIdentifier: config.workingTimeCalendarId) else {
      logger.error("Working time calendar not found: \(config.workingTimeCalendarId)")
      return CalculationResult(
        range: DateRange(start: start, end: end),
        totalWorkingSeconds: 0, totalExcludedSeconds: 0, netCapExSeconds: 0, dailyStats: [:])
    }

    let workingEvents = fetchEvents(calendars: [workingCal], start: start, end: end)
    
    // Convert to candidate ranges
    // Note: We clamp events to the analysis window [start, end]
    var candidateRanges = workingEvents.compactMap { ev -> DateRange? in
        guard let s = ev.startDate, let e = ev.endDate else { return nil }
        let clampedStart = max(start, s)
        let clampedEnd = min(end, e)
        if clampedStart < clampedEnd {
            return DateRange(start: clampedStart, end: clampedEnd)
        }
        return nil
    }

    // Flatten overlapping working times handled in compute
    // candidateRanges are raw clipped ranges
    
    // 2. Process Rules (Exclusions)
    var exclusionRanges: [DateRange] = []
    
    for rule in config.rules {
        guard let cal = store.calendar(withIdentifier: rule.calendarId) else { continue }
        let events = fetchEvents(calendars: [cal], start: start, end: end)
        
        for ev in events {
            if matches(event: ev, rule: rule) {
                guard let s = ev.startDate, let e = ev.endDate else { continue }
                let clampedStart = max(start, s)
                let clampedEnd = min(end, e)
                if clampedStart < clampedEnd {
                    exclusionRanges.append(DateRange(start: clampedStart, end: clampedEnd))
                }
            }
        }
    }
    
    return CapExEngine.compute(
        workingRanges: candidateRanges,
        exclusionRanges: exclusionRanges,
        config: config,
        start: start,
        end: end
    )
  }
  
  /// Pure logic for calculating stats, testable without EventKit.
  nonisolated static func compute(
    workingRanges: [DateRange],
    exclusionRanges: [DateRange],
    config: CapExConfigUI,
    start: Date,
    end: Date
  ) -> CalculationResult {
      // 1. Merge overlapping working times
      let mergedWorking = mergeOverlaps(workingRanges)
      let totalWorking = mergedWorking.reduce(0) { $0 + $1.duration }
      
      // 2. Merge overlapping exclusions
      let mergedExclusions = mergeOverlaps(exclusionRanges)
      
      // 3. Subtract Exclusions from Candidates
      var finalRanges = mergedWorking
      for exclusion in mergedExclusions {
          finalRanges = subtract(exclusion: exclusion, from: finalRanges)
      }
      
      let netCapEx = finalRanges.reduce(0) { $0 + $1.duration }
      
      // 4. Calculate Daily Stats
      var stats: [Date: DailyStat] = [:]
      let calendar = Calendar.current
      
      // Initialize stats for each day in range
      var curr = calendar.startOfDay(for: start)
      while curr < end {
          stats[curr] = DailyStat(date: curr)
          curr = calendar.date(byAdding: .day, value: 1, to: curr)!
      }

      // Helper to distribute duration to days
      func distribute(ranges: [DateRange], keyPath: WritableKeyPath<DailyStat, TimeInterval>) {
          for range in ranges {
              var simTime = range.start
              while simTime < range.end {
                  let dayStart = calendar.startOfDay(for: simTime)
                  guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
                  let segmentEnd = min(range.end, dayEnd)
                  let duration = segmentEnd.timeIntervalSince(simTime)
                  
                  if var stat = stats[dayStart] {
                      stat[keyPath: keyPath] += duration
                      stats[dayStart] = stat
                  }
                  simTime = segmentEnd
              }
          }
      }

      distribute(ranges: mergedWorking, keyPath: \.workingSeconds)
      distribute(ranges: finalRanges, keyPath: \.netSeconds)
      
      // Apply Percentage
      let percentage = Double(config.capExPercentage) / 100.0
      var finalNetCapEx: TimeInterval = 0
      
      for (date, stat) in stats {
          var s = stat
          
          let rawNet = s.netSeconds
          let adjustedNet = rawNet * percentage
          s.netSeconds = adjustedNet
          s.excludedSeconds = max(0, s.workingSeconds - adjustedNet)
          
          stats[date] = s
          finalNetCapEx += adjustedNet
      }
      
      let finalExcluded = totalWorking - finalNetCapEx

      return CalculationResult(
          range: DateRange(start: start, end: end),
          totalWorkingSeconds: totalWorking,
          totalExcludedSeconds: finalExcluded,
          netCapExSeconds: finalNetCapEx,
          dailyStats: stats
      )
  }

  private func fetchEvents(calendars: [EKCalendar], start: Date, end: Date) -> [EKEvent] {
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    return store.events(matching: predicate)
  }
  
  private func matches(event: EKEvent, rule: CapExRuleUI) -> Bool {
    // 1. Title Filter
    if let filter = rule.titleFilter, !filter.isEmpty {
        let title = event.title ?? ""
        if rule.matchMode == "exact" {
            if title != filter { return false }
        } else {
            // Default contains
            if !title.localizedCaseInsensitiveContains(filter) { return false }
        }
    }
    
    // 2. Participants Filter
    if let attendeesFilter = rule.participantsFilter, !attendeesFilter.isEmpty {
        let attendees = event.attendees ?? []
        let names = attendees.compactMap { $0.name }
        let emails = attendees.compactMap { $0.description } // EKParticipant description often contains email/URL
        let allText = (names + emails).joined(separator: " ").lowercased()
        
        // Simple search for now
        if !allText.contains(attendeesFilter.lowercased()) {
            return false
        }
    }
    
    return true
  }

  /// Merges overlapping time ranges into a minimal set.
  nonisolated static func mergeOverlaps(_ ranges: [DateRange]) -> [DateRange] {
    let sorted = ranges.sorted { $0.start < $1.start }
    var merged: [DateRange] = []
    
    for r in sorted {
        guard let last = merged.last else {
            merged.append(r)
            continue
        }
        
        if r.start <= last.end {
            // Overlap or adjacent
            let newEnd = max(last.end, r.end)
            merged[merged.count - 1] = DateRange(start: last.start, end: newEnd)
        } else {
            merged.append(r)
        }
    }
    return merged
  }

  /// Subtracts a single exclusion range from a list of available ranges.
  nonisolated static func subtract(exclusion: DateRange, from available: [DateRange]) -> [DateRange] {
    var result: [DateRange] = []
    
    for r in available {
        // No overlap
        if exclusion.end <= r.start || exclusion.start >= r.end {
            result.append(r)
            continue
        }
        
        // Split r by exclusion
        
        // Part before exclusion
        if r.start < exclusion.start {
            result.append(DateRange(start: r.start, end: exclusion.start))
        }
        
        // Part after exclusion
        if r.end > exclusion.end {
            result.append(DateRange(start: exclusion.end, end: r.end))
        }
    }
    
    return result
  }
}
