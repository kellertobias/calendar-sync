import XCTest

@testable import CalendarSync

final class OccurenceKeyTests: XCTestCase {
  func testOccurrenceKeyStableWithOccurrenceDate() {
    let sourceId = "EV123"
    let occ = ISO8601DateFormatter().date(from: "2024-06-01T10:00:00Z")!
    let (_, iso1, key1) = SyncRules.occurrenceComponents(
      sourceId: sourceId, occurrenceDate: occ, startDate: nil)
    let (_, iso2, key2) = SyncRules.occurrenceComponents(
      sourceId: sourceId, occurrenceDate: occ, startDate: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(iso1, iso2)
    XCTAssertEqual(key1, key2)
  }

  func testNeedsUpdateBlockerAndFull() {
    // Full mode compares title, time, location
    XCTAssertTrue(
      SyncRules.needsUpdate(
        mode: .full, template: nil, sourceTitle: "A", targetTitle: "B", sourceStart: Date(),
        targetStart: Date(), sourceEnd: nil, targetEnd: nil, sourceLocation: nil,
        targetLocation: nil))

    // Blocker mode compares computed blocker title and times only
    let sTitle = "Design Review"
    let templ = "Busy — {sourceTitle}"
    let blocked = templ.replacingOccurrences(of: "{sourceTitle}", with: sTitle)
    XCTAssertFalse(
      SyncRules.needsUpdate(
        mode: .blocker, template: templ, sourceTitle: sTitle, targetTitle: blocked,
        sourceStart: Date(timeIntervalSince1970: 100),
        targetStart: Date(timeIntervalSince1970: 100), sourceEnd: Date(timeIntervalSince1970: 200),
        targetEnd: Date(timeIntervalSince1970: 200), sourceLocation: "HQ", targetLocation: "Room 1")
    )
    XCTAssertTrue(
      SyncRules.needsUpdate(
        mode: .blocker, template: templ, sourceTitle: sTitle, targetTitle: blocked,
        sourceStart: Date(timeIntervalSince1970: 100),
        targetStart: Date(timeIntervalSince1970: 101), sourceEnd: Date(timeIntervalSince1970: 200),
        targetEnd: Date(timeIntervalSince1970: 200), sourceLocation: "HQ", targetLocation: "Room 1")
    )
  }
}
