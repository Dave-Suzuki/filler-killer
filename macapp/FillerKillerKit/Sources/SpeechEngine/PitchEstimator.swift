// Fundamental-frequency (F0) estimation for the "only count my voice" gate.
// McLeod-style normalized square difference (NSDF) over fixed windows of the
// mic tap, voiced frames only. A segment's median F0 is compared against a
// calibrated band of the user's own voice; segments that fall outside are
// skipped by the app. The gate FAILS OPEN: too few voiced frames, or no
// calibration, means the segment is counted — never silently eat the user's
// own words.
//
// Pure logic (no AVFoundation dependency) so it builds and tests on Linux CI,
// same pattern as PartialStabilizer.

import Foundation

/// Per-segment voice statistics accumulated from the mic tap between segment
/// commits. `nil` at the call sites means "not enough voiced audio to judge".
public struct SegmentVoice: Sendable, Equatable {
    /// Median fundamental frequency of the voiced frames, in Hz.
    public let medianF0: Double
    /// How many ~50 ms analysis windows were confidently voiced.
    public let voicedFrames: Int

    public init(medianF0: Double, voicedFrames: Int) {
        self.medianF0 = medianF0
        self.voicedFrames = voicedFrames
    }
}

/// The calibrated F0 range of the user's own voice.
public struct VoiceBand: Sendable, Equatable {
    public let lowF0: Double
    public let highF0: Double

    public init(lowF0: Double, highF0: Double) {
        self.lowF0 = lowF0
        self.highF0 = highF0
    }

    /// Build a band from raw voiced-frame F0s collected during calibration:
    /// p10…p90 widened by `margin` Hz, so a normal reading voice defines the
    /// band without outlier frames (creaks, octave slips) stretching it.
    /// Returns nil when there aren't enough voiced frames to trust.
    public static func calibrated(
        from f0s: [Double], margin: Double = 20, minSamples: Int = 25
    ) -> VoiceBand? {
        guard f0s.count >= minSamples else { return nil }
        let sorted = f0s.sorted()
        let p10 = sorted[sorted.count / 10]
        let p90 = sorted[(sorted.count * 9) / 10 - 1]
        return VoiceBand(lowF0: max(50, p10 - margin), highF0: p90 + margin)
    }

    /// True when a segment should NOT be counted: confidently voiced (enough
    /// frames) with a median pitch outside this band. Ambiguous segments
    /// (nil stats, few voiced frames) are never skipped.
    public func shouldSkip(_ voice: SegmentVoice?, minVoicedFrames: Int = 8) -> Bool {
        guard let voice, voice.voicedFrames >= minVoicedFrames else { return false }
        return voice.medianF0 < lowF0 || voice.medianF0 > highF0
    }
}

public struct PitchEstimator: Sendable {
    /// Plausible speaking-voice F0; estimates outside are treated as unvoiced.
    public static let f0Range = 60.0 ... 400.0
    /// NSDF peak clarity below this means "not confidently periodic".
    static let clarityThreshold = 0.8
    /// Windows quieter than this RMS are silence, not speech.
    static let silenceRMS = 0.005
    /// Backstop so a pathological no-commit session can't grow unbounded.
    static let maxStoredF0s = 4000

    public let sampleRate: Double

    private let decimation: Int
    private let workRate: Double
    private let windowSize: Int
    private let minLag: Int
    private let maxLag: Int

    private var decimSum: Double = 0
    private var decimCount = 0
    private var window: [Float] = []
    private var f0s: [Double] = []

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Decimate to ~12 kHz: pitch needs nothing above f0Range, and the
        // boxcar average that does the decimating doubles as a crude
        // anti-alias low-pass. Keeps the per-window NSDF cheap enough for
        // the audio tap thread.
        decimation = max(1, Int(sampleRate / 12000))
        workRate = sampleRate / Double(decimation)
        minLag = Int(workRate / Self.f0Range.upperBound)
        maxLag = Int(workRate / Self.f0Range.lowerBound)
        windowSize = Int(workRate * 0.05) // 50 ms ≥ 2.5× maxLag at any rate
        window.reserveCapacity(windowSize)
    }

    /// Feed raw mono samples (any chunking — results are identical however
    /// the stream is split). Safe on the audio tap thread: allocation-free
    /// after warm-up, ~0.1 ms of math per 50 ms window.
    public mutating func process(_ samples: UnsafePointer<Float>, count: Int) {
        for i in 0 ..< count {
            decimSum += Double(samples[i])
            decimCount += 1
            if decimCount == decimation {
                window.append(Float(decimSum / Double(decimation)))
                decimSum = 0
                decimCount = 0
                if window.count == windowSize {
                    analyzeWindow()
                    window.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    public mutating func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                process(base, count: buf.count)
            }
        }
    }

    /// Consume the stats accumulated since the last take/reset — called when
    /// a segment commits, so the stats describe that segment's audio.
    public mutating func takeSegmentVoice() -> SegmentVoice? {
        let taken = takeF0s()
        guard !taken.isEmpty else { return nil }
        let sorted = taken.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
        return SegmentVoice(medianF0: median, voicedFrames: taken.count)
    }

    /// Consume the raw voiced-frame F0s — calibration wants the distribution,
    /// not just the median.
    public mutating func takeF0s() -> [Double] {
        let taken = f0s
        f0s = []
        return taken
    }

    public mutating func reset() {
        decimSum = 0
        decimCount = 0
        window.removeAll(keepingCapacity: true)
        f0s = []
    }

    // MARK: - Internals

    /// NSDF (McLeod/MPM): nsdf[τ] = 2·Σx[i]x[i+τ] / Σ(x[i]² + x[i+τ]²).
    /// The first local maximum within 10% of the global maximum is the
    /// period — picking the FIRST avoids latching onto a subharmonic.
    private mutating func analyzeWindow() {
        var energy = 0.0
        for s in window {
            energy += Double(s) * Double(s)
        }
        let rms = (energy / Double(window.count)).squareRoot()
        guard rms > Self.silenceRMS else { return }

        var nsdf = [Double](repeating: 0, count: maxLag + 2)
        for tau in minLag ... maxLag {
            var acf = 0.0
            var norm = 0.0
            for i in 0 ..< (windowSize - tau) {
                let a = Double(window[i])
                let b = Double(window[i + tau])
                acf += a * b
                norm += a * a + b * b
            }
            nsdf[tau] = norm > 0 ? 2 * acf / norm : 0
        }

        var peaks: [(lag: Int, value: Double)] = []
        var best = 0.0
        for tau in (minLag + 1) ..< maxLag
            where nsdf[tau] > 0 && nsdf[tau] >= nsdf[tau - 1] && nsdf[tau] >= nsdf[tau + 1] {
            peaks.append((tau, nsdf[tau]))
            best = max(best, nsdf[tau])
        }
        guard best >= Self.clarityThreshold,
              let peak = peaks.first(where: { $0.value >= 0.9 * best })
        else { return }

        // Parabolic refinement around the integer-lag peak.
        let y1 = nsdf[peak.lag - 1], y2 = nsdf[peak.lag], y3 = nsdf[peak.lag + 1]
        let denom = y1 - 2 * y2 + y3
        let delta = denom != 0 ? 0.5 * (y1 - y3) / denom : 0
        let f0 = workRate / (Double(peak.lag) + max(-0.5, min(0.5, delta)))
        guard Self.f0Range.contains(f0), f0s.count < Self.maxStoredF0s else { return }
        f0s.append(f0)
    }
}
