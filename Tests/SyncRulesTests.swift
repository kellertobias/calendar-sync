import XCTest

@testable import CalendarSync

final class SyncRulesTests: XCTestCase {
  func testExtractMarkerFromNotes() {
    let notes = "Some text\n[CalendarSync] tuple=ABC source=SID occ=2024-06-01T10:00:00Z"
    let m = SyncRules.extractMarker(notes: notes, urlString: nil)
    XCTAssertEqual(m, .some(.init(tuple: "ABC", source: "SID", occ: "2024-06-01T10:00:00Z")))
  }

  func testExtractMarkerFromURL() {
    let url = "[CalendarSync] tuple=XYZ source=S2 occ=2024-07-01T08:30:00Z"
    let m = SyncRules.extractMarker(notes: nil, urlString: url)
    XCTAssertEqual(m?.tuple, "XYZ")
    XCTAssertEqual(m?.source, "S2")
  }

  func testFiltersIncludeExclude() {
    let cfg = UUID()
    let include = FilterRuleUI(type: .includeTitle, pattern: "Standup", caseSensitive: false)
    XCTAssertTrue(
      SyncRules.passesFilters(
        title: "Daily standup", location: nil, notes: nil, organizer: nil, filters: [include],
        sourceNotes: nil, sourceURLString: nil))
    XCTAssertFalse(
      SyncRules.passesFilters(
        title: "Planning", location: nil, notes: nil, organizer: nil, filters: [include],
        sourceNotes: nil, sourceURLString: nil))

    let exclude = FilterRuleUI(type: .excludeTitle, pattern: "Private", caseSensitive: false)
    XCTAssertFalse(
      SyncRules.passesFilters(
        title: "Private: Doctor", location: nil, notes: nil, organizer: nil, filters: [exclude],
        sourceNotes: nil, sourceURLString: nil))
    XCTAssertTrue(
      SyncRules.passesFilters(
        title: "Public", location: nil, notes: nil, organizer: nil, filters: [exclude],
        sourceNotes: nil, sourceURLString: nil))
  }

  func testFiltersRegexCaseSensitivity() {
    let cfg = UUID()
    let inc = FilterRuleUI(type: .includeRegex, pattern: "^Review \\d+", caseSensitive: true)
    XCTAssertTrue(
      SyncRules.passesFilters(
        title: "Review 123", location: nil, notes: nil, organizer: nil, filters: [inc],
        sourceNotes: nil, sourceURLString: nil))
    XCTAssertFalse(
      SyncRules.passesFilters(
        title: "review 123", location: nil, notes: nil, organizer: nil, filters: [inc],
        sourceNotes: nil, sourceURLString: nil))

    let exc = FilterRuleUI(type: .excludeRegex, pattern: "(?i)secret", caseSensitive: false)
    XCTAssertFalse(
      SyncRules.passesFilters(
        title: "Top Secret", location: nil, notes: nil, organizer: nil, filters: [exc],
        sourceNotes: nil, sourceURLString: nil))
  }

  func testIgnoreSyncedEventsSkipsWhenNotesContainPhrase() {
    let cfg = UUID()
    // Description contains the human-readable marker used by CalendarSync for synced events.
    let notes = "This was created by Tobisk Calendar Sync — do not edit."
    let rule = FilterRuleUI(type: .ignoreOtherTuples, pattern: "", caseSensitive: false)
    XCTAssertFalse(
      SyncRules.passesFilters(
        title: "Anything", location: nil, notes: notes, organizer: nil, filters: [rule],
        sourceNotes: notes, sourceURLString: nil))
  }

  func testLocationAndOrganizerFilters() {
    let cfg = UUID()
    let locInc = FilterRuleUI(type: .includeLocation, pattern: "HQ", caseSensitive: false)
    XCTAssertTrue(
      SyncRules.passesFilters(
        title: "", location: "HQ-1", notes: nil, organizer: nil, filters: [locInc],
        sourceNotes: nil, sourceURLString: nil))

    let orgRx = FilterRuleUI(type: .includeOrganizerRegex, pattern: "^alice@", caseSensitive: false)
    XCTAssertTrue(
      SyncRules.passesFilters(
        title: "", location: nil, notes: nil, organizer: "alice@example.com", filters: [orgRx],
        sourceNotes: nil, sourceURLString: nil))
  }

  func testTimeWindowsBoundaries() throws {
    // Mon 9:00-17:00 window
    let window = TimeWindowUI(
      weekday: .monday, start: TimeOfDay(hour: 9, minute: 0), end: TimeOfDay(hour: 17, minute: 0))
    // Create a Monday anchor date: 2024-06-03 is a Monday
    var comps = DateComponents()
    comps.year = 2024
    comps.month = 6
    comps.day = 3
    comps.hour = 9
    comps.minute = 0
    let cal = Calendar(identifier: .gregorian)
    let startIn = cal.date(from: comps)
    XCTAssertTrue(
      SyncRules.allowedByTimeWindows(start: startIn, isAllDay: false, windows: [window]))

    // Boundary end (exclusive)
    comps.hour = 17
    comps.minute = 0
    let endAt = cal.date(from: comps)
    XCTAssertFalse(SyncRules.allowedByTimeWindows(start: endAt, isAllDay: false, windows: [window]))
    // All-day excluded when windows provided
    XCTAssertFalse(
      SyncRules.allowedByTimeWindows(start: startIn, isAllDay: true, windows: [window]))
  }
}
