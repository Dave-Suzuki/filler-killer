// Commit-on-stability for partial transcriptions. Newer macOS on-device
// recognition can amend a partial forever without ever delivering isFinal —
// and without the routine silence errors server mode emits — so a pipeline
// that only counts finalized segments counts nothing (field report: "audio
// flowing", "hearing you…", then silence). A partial that stops changing for
// `commitAfter` seconds is treated as final by the caller.
//
// Pure logic (no Speech dependency) so it builds and tests on Linux CI.
// Mirrors src/fillerkiller/realtime/stabilizer.py.

import Foundation

public struct PartialStabilizer: Sendable {
    public let commitAfter: TimeInterval
    private var text = ""
    private var changedAt: Date?

    public init(commitAfter: TimeInterval = 1.75) {
        self.commitAfter = commitAfter
    }

    /// Record the latest partial transcription (each partial rewrites the
    /// whole utterance). The stability clock only restarts when the text
    /// actually changes.
    public mutating func observe(_ partial: String, at now: Date) {
        guard partial != text else { return }
        text = partial
        changedAt = now
    }

    /// The partial, if it's non-blank and hasn't changed for `commitAfter`.
    /// Consuming: state resets so the same text can't commit twice.
    public mutating func takeStable(at now: Date) -> String? {
        guard let changedAt,
              now.timeIntervalSince(changedAt) >= commitAfter,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let stable = text
        reset()
        return stable
    }

    public mutating func reset() {
        text = ""
        changedAt = nil
    }
}
