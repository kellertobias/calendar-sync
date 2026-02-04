import XCTest

@testable import CalendarSync

final class DeletionSafetyTests: XCTestCase {
  func testSafeToDeletePolicy() {
    let marker = SyncRules.Marker(
      tuple: nil, name: nil, source: "S", occ: "2024-06-01T00:00:00Z", key: nil)
    // Must match target calendar and have a CalendarSync marker
    XCTAssertTrue(
      SyncRules.safeToDeletePolicy(
        targetCalendarId: "target.cal", eventCalendarId: "target.cal", marker: marker,
        expectedTupleId: UUID(), expectedEncodedName: ""))
    XCTAssertFalse(
      SyncRules.safeToDeletePolicy(
        targetCalendarId: "target.cal", eventCalendarId: "other.cal", marker: marker,
        expectedTupleId: UUID(), expectedEncodedName: ""))
    XCTAssertFalse(
      SyncRules.safeToDeletePolicy(
        targetCalendarId: "target.cal", eventCalendarId: "target.cal", marker: nil,
        expectedTupleId: UUID(), expectedEncodedName: ""))
  }
}
