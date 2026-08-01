// Mirrors tests/test_realtime_counter.py's replay test — same segments, same
// expected numbers, so the Swift session model matches the Python prototype.

import XCTest
@testable import SessionKit

private let segments = [
    "Um so I wanted to walk through the plan",
    "it was kind of hard to schedule",
    "I I think we should you know just ship it",
    "the launch date holds",
]

final class LiveSessionCounterTests: XCTestCase {
    func testReplayAccumulatesCounts() {
        let counter = LiveSessionCounter()
        for segment in segments {
            counter.addFinal(segment)
        }
        let terms = counter.hits.map { $0.term }
        XCTAssertTrue(terms.contains("um"))
        XCTAssertTrue(terms.contains("so"))
        XCTAssertTrue(terms.contains("kind of"))
        XCTAssertTrue(terms.contains("i i"))
        XCTAssertTrue(terms.contains("you know"))
        XCTAssertEqual(counter.wordCount, 30)
        XCTAssertGreaterThan(counter.per100Words, 0)
    }

    func testAddFinalReturnsNewHitsOnly() {
        let counter = LiveSessionCounter()
        let first = counter.addFinal("you know the plan")
        let second = counter.addFinal("nothing wrong here")
        XCTAssertEqual(first.map { $0.term }, ["you know"])
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(counter.fillerCount, 1)
    }

    func testStatusLineFormat() {
        let counter = LiveSessionCounter()
        counter.addFinal("um the plan is set")
        XCTAssertTrue(counter.statusLine().hasPrefix("FK 1 ·"))
    }

    func testEmptySessionZeroRate() {
        XCTAssertEqual(LiveSessionCounter().per100Words, 0.0)
    }

    func testHitsCarrySegmentIndices() {
        let counter = LiveSessionCounter()
        counter.addFinal("nothing here")
        counter.addFinal("you know the drill")
        let hit = counter.hits.first
        XCTAssertEqual(hit?.utteranceIdx, 1)
    }
}
