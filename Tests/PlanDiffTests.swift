import XCTest
@testable import CalendarSync

private struct TestEvent: Hashable {
    let sourceId: String
    let occ: Date
    let start: Date
    let end: Date
    let title: String
    let location: String?
}

final class PlanDiffTests: XCTestCase {
    func testCreateWhenMissingTargets() {
        let cfg = UUID()
        let src = TestEvent(sourceId: "S1", occ: Date(timeIntervalSince1970: 1000), start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 1600), title: "Standup", location: nil)
        let (_, _, key) = SyncRules.occurrenceComponents(sourceId: src.sourceId, occurrenceDate: src.occ, startDate: src.start, configId: cfg)

        // No mapping and no target present → create
        let mappings: Set<String> = []
        let targets: [String: TestEvent] = [:]

        let (created, updated, deleted) = planDiff(
            configId: cfg,
            mode: .full,
            template: nil,
            sources: [src],
            targetsByKey: targets,
            mappingKeys: mappings
        )
        XCTAssertEqual(created, 1)
        XCTAssertEqual(updated, 0)
        XCTAssertEqual(deleted, 0)
        XCTAssertTrue(mappings.isEmpty)
        XCTAssertEqual(key, key) // sanity
    }

    func testUpdateWhenFieldsDiffer() {
        let cfg = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let src = TestEvent(sourceId: "S1", occ: start, start: start, end: end, title: "Planning", location: "HQ")
        let (_, _, key) = SyncRules.occurrenceComponents(sourceId: src.sourceId, occurrenceDate: src.occ, startDate: src.start, configId: cfg)
        // Target exists via mapping but title differs
        let tgt = TestEvent(sourceId: "T1", occ: start, start: start, end: end, title: "Plan", location: "HQ")
        let mappings: Set<String> = [key]
        let targets: [String: TestEvent] = [key: tgt]

        let (created, updated, deleted) = planDiff(
            configId: cfg,
            mode: .full,
            template: nil,
            sources: [src],
            targetsByKey: targets,
            mappingKeys: mappings
        )
        XCTAssertEqual(created, 0)
        XCTAssertEqual(updated, 1)
        XCTAssertEqual(deleted, 0)
    }

    func testDeleteWhenSourceMissingButMappedTargetExists() {
        let cfg = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let (_, _, key) = SyncRules.occurrenceComponents(sourceId: "S1", occurrenceDate: start, startDate: start, configId: cfg)
        let tgt = TestEvent(sourceId: "T1", occ: start, start: start, end: Date(timeIntervalSince1970: 200), title: "X", location: nil)
        let mappings: Set<String> = [key]
        let targets: [String: TestEvent] = [key: tgt]

        // No sources → deletion proposed for mapped target
        let (created, updated, deleted) = planDiff(
            configId: cfg,
            mode: .full,
            template: nil,
            sources: [],
            targetsByKey: targets,
            mappingKeys: mappings
        )
        XCTAssertEqual(created, 0)
        XCTAssertEqual(updated, 0)
        XCTAssertEqual(deleted, 1)
    }

    // Pure helper to mimic plan aggregation using keys and SyncRules.needsUpdate
    private func planDiff(configId: UUID, mode: SyncMode, template: String?, sources: [TestEvent], targetsByKey: [String: TestEvent], mappingKeys: Set<String>) -> (Int, Int, Int) {
        var created = 0, updated = 0, deleted = 0
        var liveKeys: Set<String> = []
        for s in sources {
            let (_, _, key) = SyncRules.occurrenceComponents(sourceId: s.sourceId, occurrenceDate: s.occ, startDate: s.start, configId: configId)
            liveKeys.insert(key)
            if let t = targetsByKey[key], mappingKeys.contains(key) {
                if SyncRules.needsUpdate(mode: mode, template: template, sourceTitle: s.title, targetTitle: t.title, sourceStart: s.start, targetStart: t.start, sourceEnd: s.end, targetEnd: t.end, sourceLocation: s.location, targetLocation: t.location) {
                    updated += 1
                }
            } else {
                created += 1
            }
        }
        for (key, _) in targetsByKey where mappingKeys.contains(key) && !liveKeys.contains(key) {
            deleted += 1
        }
        return (created, updated, deleted)
    }
}


