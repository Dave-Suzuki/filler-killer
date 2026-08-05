// PitchEstimator is pure Swift, so these run on Linux CI even though the
// transcriber itself is compiled out there.

import SpeechEngine
import XCTest

final class PitchEstimatorTests: XCTestCase {
    private let sampleRate = 48000.0

    private func sine(_ f0: Double, seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0 ..< n).map { i in
            amplitude * Float(sin(2 * .pi * f0 * Double(i) / sampleRate))
        }
    }

    /// Harmonic-rich signal — checks the estimator locks onto the fundamental
    /// rather than a harmonic or subharmonic.
    private func sawtooth(_ f0: Double, seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0 ..< n).map { i in
            let phase = f0 * Double(i) / sampleRate
            return amplitude * Float(2 * (phase - (phase + 0.5).rounded(.down)))
        }
    }

    func testSineAtMalePitch() {
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process(sine(120, seconds: 1.0))
        let voice = estimator.takeSegmentVoice()
        XCTAssertNotNil(voice)
        XCTAssertEqual(voice!.medianF0, 120, accuracy: 4)
        XCTAssertGreaterThan(voice!.voicedFrames, 10)
    }

    func testSawtoothAtFemalePitch() {
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process(sawtooth(210, seconds: 1.0))
        let voice = estimator.takeSegmentVoice()
        XCTAssertNotNil(voice)
        XCTAssertEqual(voice!.medianF0, 210, accuracy: 6)
        XCTAssertGreaterThan(voice!.voicedFrames, 10)
    }

    func testSilenceIsUnvoiced() {
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process([Float](repeating: 0, count: 48000))
        XCTAssertNil(estimator.takeSegmentVoice())
    }

    func testNoiseIsUnvoiced() {
        // Deterministic LCG noise — aperiodic, so NSDF clarity stays low.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        let noise = (0 ..< 48000).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.6
        }
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process(noise)
        XCTAssertNil(estimator.takeSegmentVoice())
    }

    func testBelowSpeechRangeIsUnvoiced() {
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process(sine(30, seconds: 1.0))
        XCTAssertNil(estimator.takeSegmentVoice())
    }

    func testChunkingDoesNotChangeTheResult() {
        let signal = sawtooth(150, seconds: 1.0)
        var whole = PitchEstimator(sampleRate: sampleRate)
        whole.process(signal)
        var chunked = PitchEstimator(sampleRate: sampleRate)
        // Ragged chunk size on purpose: window boundaries must not align.
        var i = 0
        while i < signal.count {
            let end = min(i + 941, signal.count)
            chunked.process(Array(signal[i ..< end]))
            i = end
        }
        XCTAssertEqual(whole.takeSegmentVoice(), chunked.takeSegmentVoice())
    }

    func testTakeConsumesTheStats() {
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process(sine(120, seconds: 0.5))
        XCTAssertNotNil(estimator.takeSegmentVoice())
        XCTAssertNil(estimator.takeSegmentVoice(), "stats must not double-count")
    }

    func testSegmentBoundaries() {
        // Two "speakers" separated by a take: each segment gets its own median.
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process(sine(110, seconds: 0.6))
        let first = estimator.takeSegmentVoice()
        estimator.process(sine(220, seconds: 0.6))
        let second = estimator.takeSegmentVoice()
        XCTAssertEqual(first!.medianF0, 110, accuracy: 4)
        XCTAssertEqual(second!.medianF0, 220, accuracy: 6)
    }

    // MARK: - VoiceBand

    func testCalibrationBandFromSpread() {
        // 100 voiced frames spread 100…139 Hz plus outliers that p10/p90
        // should shrug off.
        var f0s = (0 ..< 100).map { 100.0 + Double($0 % 40) }
        f0s.append(contentsOf: [62.0, 63.0, 380.0, 390.0])
        let band = VoiceBand.calibrated(from: f0s, margin: 20)
        XCTAssertNotNil(band)
        XCTAssertEqual(band!.lowF0, 84, accuracy: 4)
        XCTAssertEqual(band!.highF0, 156, accuracy: 4)
    }

    func testCalibrationNeedsEnoughFrames() {
        XCTAssertNil(VoiceBand.calibrated(from: [120, 121, 122]))
    }

    func testCalibrationFloorsTheLowEdge() {
        let f0s = [Double](repeating: 62, count: 30)
        XCTAssertEqual(VoiceBand.calibrated(from: f0s)?.lowF0, 50)
    }

    func testGateFailsOpen() {
        let band = VoiceBand(lowF0: 90, highF0: 160)
        XCTAssertFalse(band.shouldSkip(nil), "no stats → count it")
        XCTAssertFalse(
            band.shouldSkip(SegmentVoice(medianF0: 220, voicedFrames: 3)),
            "too few voiced frames → count it"
        )
    }

    func testGateSkipsOutOfBandAndKeepsInBand() {
        let band = VoiceBand(lowF0: 90, highF0: 160)
        XCTAssertTrue(band.shouldSkip(SegmentVoice(medianF0: 210, voicedFrames: 20)))
        XCTAssertTrue(band.shouldSkip(SegmentVoice(medianF0: 75, voicedFrames: 20)))
        XCTAssertFalse(band.shouldSkip(SegmentVoice(medianF0: 120, voicedFrames: 20)))
    }

    func testEndToEndGate() {
        // The whole pipeline: calibrate on a 120 Hz voice, then a 210 Hz
        // segment is skipped and a 125 Hz segment is kept.
        var calibration = PitchEstimator(sampleRate: sampleRate)
        calibration.process(sine(120, seconds: 2.0))
        guard let band = VoiceBand.calibrated(from: calibration.takeF0s()) else {
            return XCTFail("calibration produced no band")
        }
        var estimator = PitchEstimator(sampleRate: sampleRate)
        estimator.process(sawtooth(210, seconds: 1.0))
        XCTAssertTrue(band.shouldSkip(estimator.takeSegmentVoice()))
        estimator.process(sine(125, seconds: 1.0))
        XCTAssertFalse(band.shouldSkip(estimator.takeSegmentVoice()))
    }
}
