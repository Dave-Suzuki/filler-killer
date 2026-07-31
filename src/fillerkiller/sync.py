"""Pull meetings from a GranolaSource, run the detector, persist to SQLite.

Incremental: a meeting is re-analyzed only if it's new or its updated_at
changed (Granola updates transcripts for a while after a meeting ends).
Vocalized fillers (um/uh) are excluded on this path — Granola's ASR strips
them, so counting them here would just misstate the post-hoc rates.
"""

import sqlite3
from datetime import datetime, timezone

from fillerkiller.detector import analyze_utterances
from fillerkiller.granola.source import GranolaSource, Meeting


def default_source(force_api: bool = False, legacy: bool = False) -> GranolaSource:
    """GRANOLA_API_KEY (official API) wins; otherwise the local cache file.
    legacy forces the old unofficial-API path for pre-encryption installs."""
    from fillerkiller import config

    if legacy:
        from fillerkiller.granola.api_source import ApiSource

        return ApiSource()
    if force_api or config.granola_api_key():
        from fillerkiller.granola.public_api_source import PublicApiSource

        return PublicApiSource()
    from fillerkiller.granola.cache_source import CacheSource

    return CacheSource()


def sync_meetings(conn: sqlite3.Connection, source: GranolaSource) -> dict:
    known = {
        row["id"]: row["updated_at"]
        for row in conn.execute("SELECT id, updated_at FROM meetings")
    }
    if hasattr(source, "set_known"):
        source.set_known(known)  # lets API sources skip transcript fetches
    added = updated = skipped = 0
    for meeting in source.meetings():
        if meeting.id in known:
            if known[meeting.id] == meeting.updated_at:
                skipped += 1
                continue
            updated += 1
        else:
            added += 1
        _store_meeting(conn, meeting)
    conn.commit()
    return {"added": added, "updated": updated, "skipped": skipped}


def _store_meeting(conn: sqlite3.Connection, meeting: Meeting) -> None:
    result = analyze_utterances(meeting.utterances, speaker="Me", include_vocalized=False)
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("DELETE FROM meetings WHERE id = ?", (meeting.id,))
    conn.execute(
        "INSERT INTO meetings (id, title, started_at, updated_at, word_count,"
        " filler_count, per_100_words, synced_at) VALUES (?,?,?,?,?,?,?,?)",
        (
            meeting.id,
            meeting.title,
            meeting.started_at,
            meeting.updated_at,
            result.word_count,
            result.filler_count,
            result.per_100_words,
            now,
        ),
    )
    conn.executemany(
        "INSERT INTO utterances (meeting_id, idx, speaker, text) VALUES (?,?,?,?)",
        [(meeting.id, i, u.speaker, u.text) for i, u in enumerate(meeting.utterances)],
    )
    conn.executemany(
        "INSERT INTO filler_hits (meeting_id, utterance_idx, term, category, start, end)"
        " VALUES (?,?,?,?,?,?)",
        [(meeting.id, h.utterance_idx, h.term, h.category, h.start, h.end) for h in result.hits],
    )
