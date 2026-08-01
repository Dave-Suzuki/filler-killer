// SQLite persistence — the exact prototype schema from
// src/fillerkiller/store/db.py, so the Python tool's fk.db imports as a plain
// file copy and both implementations stay queryable by the same SQL.

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
        synced_at TEXT NOT NULL
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

    public func savedSessionCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM live_sessions WHERE ended_at IS NOT NULL"
            ) ?? 0
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
        return true
    }
}
