import DetectorKit
import GRDB
import XCTest
@testable import SessionStore

final class SessionStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("fk.db")
    }

    func testRecorderRoundtrip() throws {
        let store = try SessionStore(url: tempURL())
        let recorder = LiveSessionRecorder(store: store)
        try recorder.begin()

        let texts = ["Um so I think this works", "nothing wrong here"]
        for (idx, text) in texts.enumerated() {
            let hits = analyzeText(text, utteranceIdx: idx, includeVocalized: true)
            try recorder.record(segmentIdx: idx, text: text, at: Date(), hits: hits)
        }
        let id = try recorder.finish(
            label: "test call", wordCount: 8, fillerCount: 2, per100Words: 25.0
        )
        XCTAssertNotNil(id)

        try store.pool.read { db in
            guard let session = try Row.fetchOne(
                db, sql: "SELECT * FROM live_sessions WHERE id = ?", arguments: [id]
            ) else {
                return XCTFail("session row missing")
            }
            XCTAssertEqual(session["label"] as String?, "test call")
            XCTAssertNotNil(session["ended_at"] as String?)
            let segments = try Row.fetchAll(
                db, sql: "SELECT idx, text FROM live_segments WHERE session_id = ? ORDER BY idx",
                arguments: [id]
            )
            XCTAssertEqual(segments.map { $0["text"] as String }, texts)
            // Every hit's span slices back to its term within its segment.
            let hits = try Row.fetchAll(
                db,
                sql: "SELECT segment_idx, term, start, \"end\" FROM live_hits WHERE session_id = ?",
                arguments: [id]
            )
            XCTAssertFalse(hits.isEmpty)
            for hit in hits {
                let text = texts[hit["segment_idx"] as Int]
                let scalars = Array(text.unicodeScalars)
                let start = hit["start"] as Int
                let end = hit["end"] as Int
                var view = String.UnicodeScalarView()
                for scalar in scalars[start ..< end] { view.append(scalar) }
                XCTAssertEqual(String(view).lowercased(), hit["term"] as String)
            }
        }
        XCTAssertEqual(try store.savedSessionCount(), 1)
    }

    func testRescoreHealsStaleHits() async throws {
        let store = try SessionStore(url: tempURL())
        // A meeting scored by the OLD detector: "it it" was flagged as a
        // stutter. The re-scored meeting must drop it — and ALSO drop the
        // genuine "the the": repeats never count on the Granola path (its
        // ASR injects doubled words), only live sessions keep them.
        try await store.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, word_count,
                    filler_count, per_100_words, synced_at, self_speaker)
                VALUES ('m1', 'Standup', '2026-08-01T10:00:00Z', 6, 1, 16.67,
                    '2026-08-01T12:00:00Z', 'Me')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO utterances (meeting_id, idx, speaker, text)
                VALUES ('m1', 0, 'Me', 'when I tried it it worked the the plan held')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO filler_hits (meeting_id, utterance_idx, term, category, start, "end")
                VALUES ('m1', 0, 'it it', 'repetition', 13, 18)
                """
            )
        }
        // A live session with one stale bogus hit on top of two real ones.
        let recorder = LiveSessionRecorder(store: store)
        try recorder.begin()
        let text = "Um so I think this works"
        try recorder.record(
            segmentIdx: 0, text: text, at: Date(),
            hits: analyzeText(text, utteranceIdx: 0, includeVocalized: true)
        )
        guard let sessionId = try recorder.finish(
            label: nil, wordCount: 6, fillerCount: 3, per100Words: 50.0
        ) else {
            return XCTFail("finish returned no id")
        }
        try await store.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO live_hits (session_id, term, category, at, segment_idx, start, "end")
                VALUES (?, 'it it', 'repetition', '2026-08-01T10:00:05Z', 0, 0, 5)
                """,
                arguments: [sessionId]
            )
        }

        let counts = try await store.rescoreAll()
        XCTAssertEqual(counts.meetings, 1)
        XCTAssertEqual(counts.sessions, 1)

        let (meetingHits, meetingFillers, sessionHits, sessionFillers) =
            try await store.pool.read { db in
                (
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM filler_hits WHERE meeting_id = 'm1'"
                    ) ?? -1,
                    try Int.fetchOne(
                        db, sql: "SELECT filler_count FROM meetings WHERE id = 'm1'"
                    ) ?? -1,
                    try Row.fetchAll(
                        db, sql: "SELECT term FROM live_hits WHERE session_id = ?",
                        arguments: [sessionId]
                    ).map { $0["term"] as String },
                    try Int.fetchOne(
                        db, sql: "SELECT filler_count FROM live_sessions WHERE id = ?",
                        arguments: [sessionId]
                    ) ?? -1
                )
            }
        XCTAssertEqual(meetingHits, 0,
                       "retracted 'it it' AND path-excluded 'the the' must disappear")
        XCTAssertEqual(meetingFillers, 0)
        XCTAssertEqual(sessionHits.sorted(), ["so", "um"], "bogus hit dropped, real hits kept")
        XCTAssertEqual(sessionFillers, 2)
    }

    func testDeleteLiveSessionCascades() throws {
        let store = try SessionStore(url: tempURL())
        let recorder = LiveSessionRecorder(store: store)
        try recorder.begin()
        let text = "Um so I think this works"
        try recorder.record(
            segmentIdx: 0, text: text, at: Date(),
            hits: analyzeText(text, utteranceIdx: 0, includeVocalized: true)
        )
        guard let id = try recorder.finish(
            label: nil, wordCount: 6, fillerCount: 2, per100Words: 33.3
        ) else {
            return XCTFail("finish returned no id")
        }
        XCTAssertEqual(try store.savedSessionCount(), 1)

        try store.deleteLiveSession(id: id)
        XCTAssertEqual(try store.savedSessionCount(), 0)
        try store.pool.read { db in
            for table in ["live_hits", "live_segments"] {
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table) WHERE session_id = ?",
                    arguments: [id]
                ) ?? -1
                XCTAssertEqual(count, 0, "\(table) rows must cascade")
            }
        }
    }

    func testCrashMidSessionKeepsSegmentsButNotInTrends() throws {
        let url = tempURL()
        let store = try SessionStore(url: url)
        let recorder = LiveSessionRecorder(store: store)
        try recorder.begin()
        try recorder.record(
            segmentIdx: 0, text: "you know the drill", at: Date(),
            hits: analyzeText("you know the drill")
        )
        // No finish() — simulate a crash; a fresh store sees the data but the
        // session is excluded from saved counts (ended_at IS NULL).
        let reopened = try SessionStore(url: url)
        let segments = try reopened.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM live_segments") ?? 0
        }
        XCTAssertEqual(segments, 1)
        XCTAssertEqual(try reopened.savedSessionCount(), 0)
    }

    func testDiscardCascades() throws {
        let store = try SessionStore(url: tempURL())
        let recorder = LiveSessionRecorder(store: store)
        try recorder.begin()
        try recorder.record(
            segmentIdx: 0, text: "um right", at: Date(), hits: analyzeText("um right")
        )
        try recorder.discard()
        try store.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM live_sessions"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM live_segments"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM live_hits"), 0)
        }
    }

    func testLegacyImportCopiesOnce() throws {
        let legacy = tempURL()
        let destination = tempURL()
        // Build a "legacy" database with one saved session.
        let legacyStore = try SessionStore(url: legacy)
        let recorder = LiveSessionRecorder(store: legacyStore)
        try recorder.begin()
        try recorder.finish(label: "old", wordCount: 1, fillerCount: 0, per100Words: 0)

        XCTAssertTrue(try LegacyImport.importIfNeeded(from: legacy, to: destination))
        let imported = try SessionStore(url: destination)
        XCTAssertEqual(try imported.savedSessionCount(), 1)
        // Second run is a no-op: destination already exists.
        XCTAssertFalse(try LegacyImport.importIfNeeded(from: legacy, to: destination))
    }
}
