import XCTest

@testable import CalendarSync

private struct TestEvent: Hashable {
  let sourceId: String
  let occ: Date
  let start: Date
  let end: Date
  let title: String
  let location: String?
  let notes: String?
}

final class PlanDiffTests: XCTestCase {
  func testDuplicatePrevention() {
    let cfg = UUID()
    let start = Date(timeIntervalSince1970: 1000)
    let end = Date(timeIntervalSince1970: 1600)
    // Source event
    let src = TestEvent(
      sourceId: "S1", occ: start, start: start, end: end, title: "Meeting", location: nil, notes: nil)
    
    // Target event that is NOT mapped but matches title/time and has sync tag
    // This simulates a "loose match" that should prevent creation
    let tgt = TestEvent(
      sourceId: "T_Legacy", occ: start, start: start, end: end, title: "Meeting", location: nil, 
      notes: "Some notes\n[CalendarSync] tuple=OLD source=S1 occ=... key=OLD")
      
    // Passed as part of "all targets" but not in mapped targets
    let allTargets = [tgt]
    let mappings: Set<String> = []
    let targetsByKey: [String: TestEvent] = [:] 

    let (created, updated, deleted) = planDiff(
      mode: .full,
      template: nil,
      sources: [src],
      targetsByKey: targetsByKey,
      allTargets: allTargets,
      mappingKeys: mappings
    )
    
    // Should be 0 created because it matched the existing one
    // Should be 1 updated because it matched and we might want to update it (or 0 if exact match)
    // In SyncEngine, if loose match is found, it becomes an update candidate. 
    // If fields match, updated=0. If fields differ, updated=1. 
    // Here fields match perfectly.
    XCTAssertEqual(created, 0)
    XCTAssertEqual(updated, 0) 
    XCTAssertEqual(deleted, 0)
  }

  // Pure helper to mimic plan aggregation using keys and SyncRules.needsUpdate
  // Updated to support loose matching logic
  private func planDiff(
    mode: SyncMode, template: String?, sources: [TestEvent], 
    targetsByKey: [String: TestEvent],
    allTargets: [TestEvent] = [], // New param for loose matching
    mappingKeys: Set<String>
  ) -> (Int, Int, Int) {
    var created = 0
    var updated = 0
    var deleted = 0
    var liveKeys: Set<String> = []
    
    // Index for loose matching: key -> [Event]
    var looseIndex: [String: [TestEvent]] = [:]
    let isoFormatter = ISO8601DateFormatter() // approximate usage
    isoFormatter.formatOptions = [.withInternetDateTime]
    isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    
    for t in allTargets {
      if t.notes?.contains("CalendarSync") == true {
        let key = "\(t.title)|\(isoFormatter.string(from: t.start))"
        looseIndex[key, default: []].append(t)
      }
    }
    
    for s in sources {
      let (_, _, key) = SyncRules.occurrenceComponents(
        sourceId: s.sourceId, occurrenceDate: s.occ, startDate: s.start)
      liveKeys.insert(key)
      
      var validTarget: TestEvent? = nil
      
      if let t = targetsByKey[key], mappingKeys.contains(key) {
        validTarget = t
      } else {
        // Loose match fallback
        let looseKey = "\(s.title)|\(isoFormatter.string(from: s.start))"
        if let candidates = looseIndex[looseKey], let first = candidates.first {
          validTarget = first
        }
      }
      
      if let t = validTarget {
        if SyncRules.needsUpdate(
          mode: mode, template: template, sourceTitle: s.title, targetTitle: t.title,
          sourceStart: s.start, targetStart: t.start, sourceEnd: s.end, targetEnd: t.end,
          sourceLocation: s.location, targetLocation: t.location)
        {
          updated += 1
        }
      } else {
        created += 1
      }
    }
    // Deletion logic (simplified for test)
    for (key, _) in targetsByKey where mappingKeys.contains(key) && !liveKeys.contains(key) {
      deleted += 1
    }
    return (created, updated, deleted)
  }
}
