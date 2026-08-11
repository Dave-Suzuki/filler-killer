// SQLite persistence — the exact prototype schema from
// src/fillerkiller/store/db.py, so the Python tool's fk.db imports as a plain
// file copy and both implementations stay queryable by the same SQL.

import DetectorKit
import Foundation
import GRDB

public final class SessionStore {
    public let pool: DatabasePool

    /// ~/Library/Application Support/FillerKiller/fk.db (the app's own copy;
    /// the Python prototype's lowercase filler-killer directory is separate).
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("FillerKiller", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fk.db")
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        pool = try DatabasePool(path: url.path)
        var migrator = DatabaseMigrator()
        // IF NOT EXISTS throughout: the same migration works on a fresh
        // database and on one imported (file-copied) from the Python tool.
        migrator.registerMigration("v1-prototype-schema") { db in
            try db.execute(sql: Self.schemaSQL)
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(live_hits)")
                .map { $0["name"] as String }
            for col in ["segment_idx", "start", "end"] where !cols.contains(col) {
                try db.execute(
                    sql: "ALTER TABLE live_hits ADD COLUMN \"\(col)\" INTEGER NOT NULL DEFAULT 0"
                )
            }
        }
        migrator.registerMigration("v2-meeting-self-speaker") { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(meetings)")
                .map { $0["name"] as String }
            if !cols.contains("self_speaker") {
                try db.execute(
                    sql: "ALTER TABLE meetings ADD COLUMN self_speaker TEXT NOT NULL DEFAULT 'Me'"
                )
            }
        }
        migrator.registerMigration("v3-meeting-owner") { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(meetings)")
                .map { $0["name"] as String }
            for col in ["owner_email", "owner_name"] where !cols.contains(col) {
                try db.execute(sql: "ALTER TABLE meetings ADD COLUMN \(col) TEXT")
            }
        }
        migrator.registerMigration("v4-excluded-meetings") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS excluded_meetings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                excluded_at TEXT NOT NULL DEFAULT ''
            )
            """)
        }
        try migrator.migrate(pool)
    }

    static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS meetings (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        started_at TEXT NOT NULL,
        updated_at TEXT,
        word_count INTEGER NOT NULL,
        filler_count INTEGER NOT NULL,
        per_100_words REAL NOT NULL,
        synced_at TEXT NOT NULL,
        self_speaker TEXT NOT NULL DEFAULT 'Me',
        owner_email TEXT,
        owner_name TEXT
    );
    CREATE TABLE IF NOT EXISTS utterances (
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL,
        speaker TEXT NOT NULL,
        text TEXT NOT NULL,
        PRIMARY KEY (meeting_id, idx)
    );
    CREATE TABLE IF NOT EXISTS filler_hits (
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        utterance_idx INTEGER NOT NULL,
        term TEXT NOT NULL,
        category TEXT NOT NULL,
        start INTEGER NOT NULL,
        end INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_hits_meeting ON filler_hits(meeting_id);
    CREATE TABLE IF NOT EXISTS live_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        label TEXT,
        word_count INTEGER NOT NULL DEFAULT 0,
        filler_count INTEGER NOT NULL DEFAULT 0,
        per_100_words REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS live_hits (
        session_id INTEGER NOT NULL REFERENCES live_sessions(id) ON DELETE CASCADE,
        term TEXT NOT NULL,
        category TEXT NOT NULL,
        at TEXT NOT NULL,
        segment_idx INTEGER NOT NULL DEFAULT 0,
        start INTEGER NOT NULL DEFAULT 0,
        end INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS live_segments (
        session_id INTEGER NOT NULL REFERENCES live_sessions(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL,
        at TEXT NOT NULL,
        text TEXT NOT NULL,
        PRIMARY KEY (session_id, idx)
    );
    """

    // MARK: - Quick stats (import verification + menu)

    public func meetingCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") ?? 0
        }
    }

    /// Privacy control: permanently remove every stored row.
    public func deleteAllData() throws {
        try pool.write { db in
            for table in ["filler_hits", "utterances", "meetings",
                          "live_hits", "live_segments", "live_sessions"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    public func savedSessionCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM live_sessions WHERE ended_at IS NOT NULL"
            ) ?? 0
        }
    }

    // MARK: - Removing records

    /// "Remove meeting": delete it AND remember the id so Granola sync never
    /// re-imports it (a plain delete comes back on the next full sync).
    /// Exclusions deliberately survive deleteAllData — they're a user
    /// preference like the Settings toggles, not meeting data.
    public func removeMeeting(id: String, title: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO excluded_meetings (id, title, excluded_at)
                VALUES (?,?,?)
                """,
                arguments: [id, title, ISO8601DateFormatter().string(from: Date())]
            )
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
    }

    /// Live sessions never re-sync from anywhere, so deleting one is final —
    /// hits and segments cascade.
    public func deleteLiveSession(id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM live_sessions WHERE id = ?", arguments: [id])
        }
    }

    public func excludedMeetingIds() throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM excluded_meetings"))
        }
    }

    public func excludedMeetingCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM excluded_meetings") ?? 0
        }
    }

    /// Forget all removals — the meetings re-import on the next Granola sync.
    public func clearExcludedMeetings() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM excluded_meetings")
        }
    }

    // MARK: - Detector-version re-score

    /// Recompute every stored meeting's and session's hits with the CURRENT
    /// detector. Stored hits are snapshots of whatever the detector said at
    /// analysis time — without this, detector fixes (e.g. the repetition
    /// false-positive fix) never reach history and Trends keeps showing
    /// retracted hits. Transcripts are the source of truth: meetings re-run
    /// vocalized-excluded (Granola path), live sessions vocalized-included,
    /// exactly like their original analyses.
    public func rescoreAll() async throws -> (meetings: Int, sessions: Int) {
        try await pool.write { db in
            var rescoredMeetings = 0
            let meetings = try Row.fetchAll(db, sql: "SELECT id, self_speaker FROM meetings")
            for row in meetings {
                let meetingId: String = row["id"]
                let speaker: String = row["self_speaker"]
                let utterances = try Row.fetchAll(
                    db,
                    sql: "SELECT speaker, text FROM utterances WHERE meeting_id = ? ORDER BY idx",
                    arguments: [meetingId]
                ).map { Utterance(speaker: $0["speaker"], text: $0["text"]) }
                guard !utterances.isEmpty else { continue }
                var result = analyzeUtterances(
                    utterances, speaker: speaker, includeVocalized: false
                )
                // Meeting path: repeats are Granola transcription noise
                // (see GranolaSyncEngine.storeMeeting); live sessions below
                // keep them.
                result.hits.removeAll { $0.category == "repetition" }
                try db.execute(
                    sql: "DELETE FROM filler_hits WHERE meeting_id = ?",
                    arguments: [meetingId]
                )
                for hit in result.hits {
                    try db.execute(
                        sql: """
                        INSERT INTO filler_hits (meeting_id, utterance_idx, term, category, start, "end")
                        VALUES (?,?,?,?,?,?)
                        """,
                        arguments: [meetingId, hit.utteranceIdx, hit.term,
                                    hit.category, hit.start, hit.end]
                    )
                }
                try db.execute(
                    sql: """
                    UPDATE meetings SET word_count = ?, filler_count = ?, per_100_words = ?
                    WHERE id = ?
                    """,
                    arguments: [result.wordCount, result.fillerCount,
                                result.per100Words, meetingId]
                )
                rescoredMeetings += 1
            }

            var rescoredSessions = 0
            let sessions = try Row.fetchAll(db, sql: "SELECT id FROM live_sessions")
            for row in sessions {
                let sessionId: Int64 = row["id"]
                let segments = try Row.fetchAll(
                    db,
                    sql: "SELECT idx, at, text FROM live_segments WHERE session_id = ? ORDER BY idx",
                    arguments: [sessionId]
                )
                guard !segments.isEmpty else { continue }
                try db.execute(
                    sql: "DELETE FROM live_hits WHERE session_id = ?",
                    arguments: [sessionId]
                )
                var fillers = 0
                var words = 0
                for segment in segments {
                    let idx: Int = segment["idx"]
                    let at: String = segment["at"]
                    let text: String = segment["text"]
                    let hits = analyzeText(text, utteranceIdx: idx, includeVocalized: true)
                    words += wordCount(text)
                    fillers += hits.count
                    for hit in hits {
                        try db.execute(
                            sql: """
                            INSERT INTO live_hits (session_id, term, category, at, segment_idx, start, "end")
                            VALUES (?,?,?,?,?,?,?)
                            """,
                            arguments: [sessionId, hit.term, hit.category, at,
                                        idx, hit.start, hit.end]
                        )
                    }
                }
                // Same round-half-to-even as LiveSessionCounter.per100Words.
                let rate = words > 0
                    ? (100.0 * Double(fillers) / Double(words) * 100)
                        .rounded(.toNearestOrEven) / 100
                    : 0.0
                try db.execute(
                    sql: """
                    UPDATE live_sessions SET word_count = ?, filler_count = ?, per_100_words = ?
                    WHERE id = ?
                    """,
                    arguments: [words, fillers, rate, sessionId]
                )
                rescoredSessions += 1
            }
            return (rescoredMeetings, rescoredSessions)
        }
    }
}

public enum LegacyImport {
    /// The Python prototype's database location.
    public static func legacyURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/filler-killer/fk.db")
    }

    /// One-time import: if the Python tool's fk.db exists and the app has no
    /// database yet, copy it (original untouched). Returns true if imported.
    @discardableResult
    public static func importIfNeeded(
        from legacy: URL? = nil, to destination: URL
    ) throws -> Bool {
        let fm = FileManager.default
        let source = legacy ?? legacyURL()
        guard fm.fileExists(atPath: source.path),
              !fm.fileExists(atPath: destination.path)
        else { return false }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.copyItem(at: source, to: destination)
        // A WAL-mode database keeps recent writes in sidecar files; copying
        // only the main file would silently drop them.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try fm.copyItem(
                    at: sidecar,
                    to: URL(fileURLWithPath: destination.path + suffix)
                )
            }
        }
        return true
    }
}
