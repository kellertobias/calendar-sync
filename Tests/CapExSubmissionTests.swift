import XCTest
@testable import CalendarSync

@MainActor final class CapExSubmissionTests: XCTestCase {
  
  // MARK: - Week Range Tests
  
  func testWeekRangeCurrentWeek() {
    let service = CapExSubmissionService()
    let (start, end) = service.weekRange(offset: 0)
    
    // Current week should contain today
    let now = Date()
    XCTAssertLessThanOrEqual(start, now)
    XCTAssertGreaterThanOrEqual(end, now)
    
    // Week should be exactly 7 days
    let duration = end.timeIntervalSince(start)
    XCTAssertEqual(duration, 7 * 24 * 3600, accuracy: 1.0)
  }
  
  func testWeekRangePreviousWeek() {
    let service = CapExSubmissionService()
    let (currentStart, _) = service.weekRange(offset: 0)
    let (prevStart, prevEnd) = service.weekRange(offset: -1)
    
    // Previous week should end exactly when current week starts
    XCTAssertEqual(prevEnd, currentStart)
    
    // Week should be exactly 7 days
    let duration = prevEnd.timeIntervalSince(prevStart)
    XCTAssertEqual(duration, 7 * 24 * 3600, accuracy: 1.0)
  }
  
  func testWeekRangeNextWeek() {
    let service = CapExSubmissionService()
    let (_, currentEnd) = service.weekRange(offset: 0)
    let (nextStart, nextEnd) = service.weekRange(offset: 1)
    
    // Next week should start exactly when current week ends
    XCTAssertEqual(nextStart, currentEnd)
    
    // Week should be exactly 7 days
    let duration = nextEnd.timeIntervalSince(nextStart)
    XCTAssertEqual(duration, 7 * 24 * 3600, accuracy: 1.0)
  }
  
  // MARK: - Should Run Now Tests
  
  func testShouldRunNowDisabled() {
    let config = CapExSubmitConfigUI(
      scriptTemplate: "echo hello",
      scheduleEnabled: false,
      scheduleDays: [.monday],
      scheduleAfterHour: 10,
      scheduleAfterMinute: 0
    )
    
    let service = CapExSubmissionService()
    XCTAssertFalse(service.shouldRunNow(submitConfig: config))
  }
  
  func testShouldRunNowEmptyScript() {
    let config = CapExSubmitConfigUI(
      scriptTemplate: "",
      scheduleEnabled: true,
      scheduleDays: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday],
      scheduleAfterHour: 0,
      scheduleAfterMinute: 0
    )
    
    let service = CapExSubmissionService()
    XCTAssertFalse(service.shouldRunNow(submitConfig: config))
  }
  
  func testShouldRunNowAlreadySubmittedThisWeek() {
    let calendar = Calendar.current
    let now = Date()
    let currentYear = calendar.component(.yearForWeekOfYear, from: now)
    let currentWeek = calendar.component(.weekOfYear, from: now)
    let weekKey = currentYear * 100 + currentWeek
    
    var config = CapExSubmitConfigUI(
      scriptTemplate: "echo hello",
      scheduleEnabled: true,
      scheduleDays: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday],
      scheduleAfterHour: 0,
      scheduleAfterMinute: 0
    )
    config.lastSubmittedWeek = weekKey
    
    let service = CapExSubmissionService()
    XCTAssertFalse(service.shouldRunNow(submitConfig: config))
  }
  
  // MARK: - Placeholder Pattern Tests
  
  @MainActor
  func testPlaceholderSubstitutionPattern() async {
    // This tests that the placeholder pattern matches correctly
    let template = "Current: {{week_capex[0]}}, Last: {{week_capex[-1]}}, Two weeks ago: {{week_capex[-2]}}"
    
    // The substitution should replace all placeholders
    // For this test, we just verify it doesn't crash and returns something
    let config = CapExConfigUI(
      workingTimeCalendarId: "",
      historyDays: 30,
      showDaily: true,
      rules: []
    )
    
    let service = CapExSubmissionService()
    let result = await service.substitutePlaceholders(template: template, config: config)
    
    // Should have replaced all placeholders (no {{ left)
    XCTAssertFalse(result.contains("{{week_capex"))
    
    // Should contain some decimal numbers (the hours)
    XCTAssertTrue(result.contains("."))
  }
  
  @MainActor
  func testPlaceholderSubstitutionNoPlaceholders() async {
    let template = "echo hello world"
    
    let config = CapExConfigUI(
      workingTimeCalendarId: "",
      historyDays: 30,
      showDaily: true,
      rules: []
    )
    
    let service = CapExSubmissionService()
    let result = await service.substitutePlaceholders(template: template, config: config)
    
    // Should remain unchanged
    XCTAssertEqual(result, template)
  }
  
  // MARK: - Error Tests
  
  @MainActor
  func testEmptyScriptError() async {
    let service = CapExSubmissionService()
    let config = CapExConfigUI(
      workingTimeCalendarId: "",
      historyDays: 30,
      showDaily: true,
      rules: []
    )
    
    do {
      _ = try await service.executeScript(template: "", config: config)
      XCTFail("Expected emptyScript error")
    } catch let error as SubmissionError {
      if case .emptyScript = error {
        // Expected
      } else {
        XCTFail("Wrong error type: \(error)")
      }
    } catch {
      XCTFail("Wrong error type: \(error)")
    }
  }
  
  @MainActor
  func testWhitespaceOnlyScriptError() async {
    let service = CapExSubmissionService()
    let config = CapExConfigUI(
      workingTimeCalendarId: "",
      historyDays: 30,
      showDaily: true,
      rules: []
    )
    
    do {
      _ = try await service.executeScript(template: "   \n\t  ", config: config)
      XCTFail("Expected emptyScript error")
    } catch let error as SubmissionError {
      if case .emptyScript = error {
        // Expected
      } else {
        XCTFail("Wrong error type: \(error)")
      }
    } catch {
      XCTFail("Wrong error type: \(error)")
    }
  }
}
