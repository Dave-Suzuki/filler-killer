import XCTest
@testable import SessionKit

final class TrendAggregatorTests: XCTestCase {
    func testDailyAverageWeightsByWords() {
        // Mirrors the Python daily(): 2 items on one day aggregate before
        // computing the rate (NOT the average of the two rates).
        let points = dailyAverage([
            RateRow(day: "2026-07-30", fillers: 1, words: 10), // 10.0 alone
            RateRow(day: "2026-07-30", fillers: 0, words: 90), // 0.0 alone
            RateRow(day: "2026-07-31", fillers: 2, words: 50),
        ])
        XCTAssertEqual(points, [
            DailyPoint(day: "2026-07-30", rate: 1.0, count: 2), // 1/100 words
            DailyPoint(day: "2026-07-31", rate: 4.0, count: 1),
        ])
    }

    func testZeroWordDaysDropped() {
        XCTAssertTrue(dailyAverage([RateRow(day: "2026-07-30", fillers: 0, words: 0)]).isEmpty)
    }

    func testBankersRounding() {
        XCTAssertEqual(weightedRate(fillers: 1, words: 32), 3.12) // 3.125 -> even
        XCTAssertEqual(weightedRate(fillers: 3, words: 32), 9.38) // 9.375 -> even
    }

    func testCutoffsOrdered() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for range in RetroRange.allCases where range != .all {
            let cutoff = range.cutoff(now: now)!
            let previous = range.previousCutoff(now: now)!
            XCTAssertLessThan(previous, cutoff)
            XCTAssertEqual(cutoff.count, 19) // YYYY-MM-DDTHH:MM:SS
        }
        XCTAssertNil(RetroRange.all.cutoff(now: now))
    }
}
