import XCTest
@testable import CalendarSync

final class CapExEngineTests: XCTestCase {
    
    // Helper to generic Date from hour
    func date(hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 1
        comps.day = 1
        comps.hour = hour
        comps.minute = 0
        return Calendar.current.date(from: comps)!
    }
    
    // Map hour range to DateRange
    func range(_ start: Int, _ end: Int) -> CapExEngine.DateRange {
        return CapExEngine.DateRange(start: date(hour: start), end: date(hour: end))
    }
    
    func testMergeOverlaps() {
        // 1. No overlap
        let r1 = range(9, 10)
        let r2 = range(11, 12)
        let merged1 = CapExEngine.mergeOverlaps([r1, r2])
        XCTAssertEqual(merged1.count, 2)
        
        // 2. Partial Overlap
        let r3 = range(9, 11)
        let r4 = range(10, 12)
        let merged2 = CapExEngine.mergeOverlaps([r3, r4])
        XCTAssertEqual(merged2.count, 1)
        XCTAssertEqual(merged2.first?.start, date(hour: 9))
        XCTAssertEqual(merged2.first?.end, date(hour: 12))
        
        // 3. Inclusion
        let r5 = range(9, 12)
        let r6 = range(10, 11)
        let merged3 = CapExEngine.mergeOverlaps([r5, r6])
        XCTAssertEqual(merged3.count, 1)
        XCTAssertEqual(merged3.first?.start, date(hour: 9))
        XCTAssertEqual(merged3.first?.end, date(hour: 12))
        
        // 4. Adjacent
        let r7 = range(9, 10)
        let r8 = range(10, 11)
        let merged4 = CapExEngine.mergeOverlaps([r7, r8])
        XCTAssertEqual(merged4.count, 1) // Should merge adjacent
        XCTAssertEqual(merged4.first?.start, date(hour: 9))
        XCTAssertEqual(merged4.first?.end, date(hour: 11))
    }
    
    func testSubtract() {
        // 1. No overlap
        let available = [range(9, 12)]
        let excl = range(13, 14)
        let res1 = CapExEngine.subtract(exclusion: excl, from: available)
        XCTAssertEqual(res1.count, 1)
        XCTAssertEqual(res1.first?.duration, 3600 * 3)
        
        // 2. Complete Overlap (erase)
        let excl2 = range(8, 13)
        let res2 = CapExEngine.subtract(exclusion: excl2, from: available)
        XCTAssertEqual(res2.count, 0)
        
        // 3. Inner Split
        let excl3 = range(10, 11)
        let res3 = CapExEngine.subtract(exclusion: excl3, from: available)
        // Should be 9-10, 11-12
        XCTAssertEqual(res3.count, 2)
        XCTAssertEqual(res3[0].end, date(hour: 10))
        XCTAssertEqual(res3[1].start, date(hour: 11))
        
        // 4. Left Cut
        let excl4 = range(8, 10)
        let res4 = CapExEngine.subtract(exclusion: excl4, from: available)
        // Should be 10-12
        XCTAssertEqual(res4.count, 1)
        XCTAssertEqual(res4[0].start, date(hour: 10))
        XCTAssertEqual(res4[0].end, date(hour: 12))
        
        // 5. Right Cut
        let excl5 = range(11, 13)
        let res5 = CapExEngine.subtract(exclusion: excl5, from: available)
        // Should be 9-11
        XCTAssertEqual(res5.count, 1)
        XCTAssertEqual(res5[0].start, date(hour: 9))
        XCTAssertEqual(res5[0].end, date(hour: 11))
    }
    
    func testPercentageApplication() {
        // Working 9-17 (8 hours)
        let working = [range(9, 17)]
        // Exclusion 12-13 (1 hour) -> 7 hours net
        let exclusion = [range(12, 13)]
        
        var config = CapExConfigUI(workingTimeCalendarId: "test", historyDays: 30, showDaily: true, rules: [])
        config.capExPercentage = 100
        
        let start = date(hour: 0)
        let end = date(hour: 24)
        
        // 100%
        let res = CapExEngine.compute(workingRanges: working, exclusionRanges: exclusion, config: config, start: start, end: end)
        XCTAssertEqual(res.totalWorkingSeconds, 8 * 3600)
        XCTAssertEqual(res.netCapExSeconds, 7 * 3600)
        XCTAssertEqual(res.totalExcludedSeconds, 1 * 3600)
        
        // 50%
        config.capExPercentage = 50
        let res50 = CapExEngine.compute(workingRanges: working, exclusionRanges: exclusion, config: config, start: start, end: end)
        XCTAssertEqual(res50.totalWorkingSeconds, 8 * 3600)
        XCTAssertEqual(res50.netCapExSeconds, 3.5 * 3600)
        XCTAssertEqual(res50.totalExcludedSeconds, 4.5 * 3600) // 1h explicit + 3.5h opEx
        
        // 0%
        config.capExPercentage = 0
        let res0 = CapExEngine.compute(workingRanges: working, exclusionRanges: exclusion, config: config, start: start, end: end)
        XCTAssertEqual(res0.netCapExSeconds, 0)
        XCTAssertEqual(res0.totalExcludedSeconds, 8 * 3600)
    }
}
