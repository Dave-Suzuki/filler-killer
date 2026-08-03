"""SQLite storage. Granola meetings and live sessions are separate tables —
they measure different filler sets (Granola lacks um/uh) — and are merged
with a source label only at the trends view."""

import sqlite3
from pathlib import Path

from fillerkiller import config

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meetings (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    started_at TEXT NOT NULL,          -- ISO 8601
    updated_at TEXT,                   -- Granola's updated stamp, for incremental sync
    word_count INTEGER NOT NULL,       -- words spoken by Me
    filler_count INTEGER NOT NULL,
    per_100_words REAL NOT NULL,
    synced_at TEXT NOT NULL,
    self_speaker TEXT NOT NULL DEFAULT 'Me',  -- counted speaker; '' = not counted
    owner_email TEXT,                         -- who captured the note (API metadata)
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


def _migrate(conn: sqlite3.Connection) -> None:
    """Additive migrations for databases created by earlier versions."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(live_hits)")}
    for col in ("segment_idx", "start", "end"):
        if col not in cols:
            conn.execute(f'ALTER TABLE live_hits ADD COLUMN "{col}" INTEGER NOT NULL DEFAULT 0')
    meeting_cols = {row[1] for row in conn.execute("PRAGMA table_info(meetings)")}
    if "self_speaker" not in meeting_cols:
        conn.execute("ALTER TABLE meetings ADD COLUMN self_speaker TEXT NOT NULL DEFAULT 'Me'")
    for col in ("owner_email", "owner_name"):
        if col not in meeting_cols:
            conn.execute(f"ALTER TABLE meetings ADD COLUMN {col} TEXT")


def connect(path: Path | None = None) -> sqlite3.Connection:
    conn = sqlite3.connect(path or config.db_path())
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(_SCHEMA)
    _migrate(conn)
    return conn
