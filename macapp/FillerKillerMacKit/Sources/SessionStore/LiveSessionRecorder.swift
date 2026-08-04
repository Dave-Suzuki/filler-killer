// Incremental live-session persistence: the session row is created at start
// (ended_at NULL) and each finalized segment + its hits are written as they
// arrive, so a crash mid-meeting can't lose the session. Trend queries filter
// on ended_at IS NOT NULL, exactly like the Python dashboard.

import DetectorKit
import Foundation
import GRDB

public final class LiveSessionRecorder {
    private let store: SessionStore
    public private(set) var sessionId: Int64?

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(store: SessionStore) {
        self.store = store
    }

    public func begin(startedAt: Date = Date()) throws {
        let stamp = Self.iso.string(from: startedAt)
        sessionId = try store.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO live_sessions (started_at, word_count, filler_count, per_100_words)
                VALUES (?, 0, 0, 0)
                """,
                arguments: [stamp]
            )
            return db.lastInsertedRowID
        }
    }

    public func record(
        segmentIdx: Int, text: String, at date: Date, hits: [FillerHit]
    ) throws {
        guard let id = sessionId else { return }
        let stamp = Self.iso.string(from: date)
        try store.pool.write { db in
            try db.execute(
                sql: "INSERT INTO live_segments (session_id, idx, at, text) VALUES (?,?,?,?)",
                arguments: [id, segmentIdx, stamp, text]
            )
            for hit in hits {
                try db.execute(
                    sql: """
                    INSERT INTO live_hits (session_id, term, category, at, segment_idx, start, "end")
                    VALUES (?,?,?,?,?,?,?)
                    """,
                    arguments: [id, hit.term, hit.category, stamp, segmentIdx, hit.start, hit.end]
                )
            }
        }
    }

    /// Finalize the session with its aggregate stats; returns the session id.
    @discardableResult
    public func finish(
        label: String?, wordCount: Int, fillerCount: Int, per100Words: Double,
        endedAt: Date = Date()
    ) throws -> Int64? {
        guard let id = sessionId else { return nil }
        let stamp = Self.iso.string(from: endedAt)
        try store.pool.write { db in
            try db.execute(
                sql: """
                UPDATE live_sessions
                SET ended_at = ?, label = ?, word_count = ?, filler_count = ?, per_100_words = ?
                WHERE id = ?
                """,
                arguments: [stamp, label, wordCount, fillerCount, per100Words, id]
            )
        }
        sessionId = nil
        return id
    }

    /// Delete the in-progress session entirely (cascades segments + hits).
    public func discard() throws {
        guard let id = sessionId else { return }
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM live_sessions WHERE id = ?", arguments: [id])
        }
        sessionId = nil
    }
}
