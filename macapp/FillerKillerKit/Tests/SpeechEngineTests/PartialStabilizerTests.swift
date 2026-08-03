// PartialStabilizer: the commit-on-stability rule that keeps live counting
// working when the recognizer never delivers isFinal (field-reported on
// newer macOS on-device recognition).

import Foundation
import SpeechEngine
import XCTest

final class PartialStabilizerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    func testCommitsAfterThresholdNotBefore() {
        var stabilizer = PartialStabilizer(commitAfter: 1.75)
        stabilizer.observe("um so basically", at: at(0))
        XCTAssertNil(stabilizer.takeStable(at: at(1.0)))
        XCTAssertNil(stabilizer.takeStable(at: at(1.74)))
        XCTAssertEqual(stabilizer.takeStable(at: at(1.75)), "um so basically")
    }

    func testAmendedTextRestartsTheClock() {
        var stabilizer = PartialStabilizer(commitAfter: 1.75)
        stabilizer.observe("um so", at: at(0))
        stabilizer.observe("um so basically we", at: at(1.5))
        XCTAssertNil(stabilizer.takeStable(at: at(2.0)), "clock restarted at 1.5")
        XCTAssertEqual(stabilizer.takeStable(at: at(3.25)), "um so basically we")
    }

    func testRepeatedIdenticalPartialsDoNotRestartTheClock() {
        var stabilizer = PartialStabilizer(commitAfter: 1.75)
        stabilizer.observe("you know", at: at(0))
        stabilizer.observe("you know", at: at(1.0))
        stabilizer.observe("you know", at: at(1.5))
        XCTAssertEqual(stabilizer.takeStable(at: at(1.75)), "you know")
    }

    func testTakeIsConsuming() {
        var stabilizer = PartialStabilizer(commitAfter: 1.0)
        stabilizer.observe("kind of done", at: at(0))
        XCTAssertEqual(stabilizer.takeStable(at: at(2)), "kind of done")
        XCTAssertNil(stabilizer.takeStable(at: at(10)), "same text must not commit twice")
    }

    func testBlankPartialsNeverCommit() {
        var stabilizer = PartialStabilizer(commitAfter: 1.0)
        stabilizer.observe("", at: at(0))
        XCTAssertNil(stabilizer.takeStable(at: at(5)))
        stabilizer.observe("   \n", at: at(6))
        XCTAssertNil(stabilizer.takeStable(at: at(20)))
    }

    func testResetClears() {
        var stabilizer = PartialStabilizer(commitAfter: 1.0)
        stabilizer.observe("i mean", at: at(0))
        stabilizer.reset()
        XCTAssertNil(stabilizer.takeStable(at: at(5)))
    }
}
