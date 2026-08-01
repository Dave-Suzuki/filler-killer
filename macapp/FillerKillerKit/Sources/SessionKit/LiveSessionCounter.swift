// Port of src/fillerkiller/realtime/counter.py — session state for the live
// listener. Transcriber-agnostic: any engine producing FINALIZED segments
// feeds addFinal(); counting finals only prevents double counting from
// interim results. Platform-neutral (tests run on Linux CI too).

import DetectorKit
import Foundation

public final class LiveSessionCounter: @unchecked Sendable {
    public struct Segment: Sendable {
        public let at: Date
        public let text: String
    }

    private let lock = NSLock()
    public let startedAt: Date
    private var _segments: [Segment] = []
    private var _hits: [FillerHit] = [] // utteranceIdx = segment index
    private var _wordCount = 0

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// Analyze a finalized segment; returns the new hits (the alert payload).
    @discardableResult
    public func addFinal(_ text: String, at date: Date = Date()) -> [FillerHit] {
        lock.lock()
        defer { lock.unlock() }
        let idx = _segments.count
        let found = analyzeText(text, utteranceIdx: idx, includeVocalized: true)
        _segments.append(Segment(at: date, text: text))
        _wordCount += DetectorKit.wordCount(text)
        _hits.append(contentsOf: found)
        return found
    }

    public var segments: [Segment] {
        lock.lock()
        defer { lock.unlock() }
        return _segments
    }

    public var hits: [FillerHit] {
        lock.lock()
        defer { lock.unlock() }
        return _hits
    }

    public var fillerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _hits.count
    }

    public var wordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wordCount
    }

    /// Matches Python round(x, 2): round-half-to-even.
    public var per100Words: Double {
        lock.lock()
        defer { lock.unlock() }
        guard _wordCount > 0 else { return 0.0 }
        let raw = 100.0 * Double(_hits.count) / Double(_wordCount)
        return (raw * 100).rounded(.toNearestOrEven) / 100
    }

    /// Short glanceable summary (the menu bar pairing proven by the prototype).
    public func statusLine() -> String {
        "FK \(fillerCount) · \(per100Words)/100w"
    }
}
