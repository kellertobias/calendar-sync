import XCTest
@testable import CalendarSync

final class DeletionSafetyTests: XCTestCase {
    func testSafeToDeletePolicy() {
        let cfg = UUID()
        let marker = SyncRules.Marker(tuple: cfg.uuidString, source: "S", occ: "2024-06-01T00:00:00Z")
        // Must match target calendar, have marker, and mapping
        XCTAssertTrue(SyncRules.safeToDeletePolicy(configId: cfg, targetCalendarId: "target.cal", eventCalendarId: "target.cal", marker: marker, hasMapping: true))
        XCTAssertFalse(SyncRules.safeToDeletePolicy(configId: cfg, targetCalendarId: "target.cal", eventCalendarId: "other.cal", marker: marker, hasMapping: true))
        XCTAssertFalse(SyncRules.safeToDeletePolicy(configId: cfg, targetCalendarId: "target.cal", eventCalendarId: "target.cal", marker: nil, hasMapping: true))
        XCTAssertFalse(SyncRules.safeToDeletePolicy(configId: cfg, targetCalendarId: "target.cal", eventCalendarId: "target.cal", marker: marker, hasMapping: false))
    }
}


