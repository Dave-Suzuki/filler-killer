"""Pull meetings from a GranolaSource, run the detector, persist to SQLite.

Incremental: a meeting is re-analyzed only if it's new or its updated_at
changed (Granola updates transcripts for a while after a meeting ends).
Vocalized fillers (um/uh) are excluded on this path — Granola's ASR strips
them, so counting them here would just misstate the post-hoc rates.

Speaker attribution: "Me" in a Granola transcript is whoever captured the
note. For shared meetings someone else recorded, the user's own words are
under their display name instead — resolve_self_speaker picks the right
label per meeting (FK_MY_NAME), and already-synced meetings are healed from
their stored utterances whenever the resolution changes.
"""

import sqlite3
from datetime import datetime, timezone

from fillerkiller.detector import Utterance, analyze_utterances
from fillerkiller.granola.source import GranolaSource, Meeting, resolve_self_speaker


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


def sync_meetings(
    conn: sqlite3.Connection, source: GranolaSource, my_names: list[str] | None = None
) -> dict:
    if my_names is None:
        from fillerkiller import config

        my_names = config.my_names()
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
        _store_meeting(conn, meeting, my_names)
    reattributed = _reattribute_stored(conn, my_names)
    conn.commit()
    return {
        "added": added,
        "updated": updated,
        "skipped": skipped,
        "reattributed": reattributed,
    }


def _analyze_and_store_counts(
    conn: sqlite3.Connection, meeting_id: str, utterances: list[Utterance],
    my_names: list[str],
) -> tuple:
    speaker = resolve_self_speaker(utterances, my_names)
    result = analyze_utterances(utterances, speaker=speaker, include_vocalized=False)
    conn.execute("DELETE FROM filler_hits WHERE meeting_id = ?", (meeting_id,))
    conn.executemany(
        "INSERT INTO filler_hits (meeting_id, utterance_idx, term, category, start, end)"
        " VALUES (?,?,?,?,?,?)",
        [(meeting_id, h.utterance_idx, h.term, h.category, h.start, h.end) for h in result.hits],
    )
    return speaker, result


def _store_meeting(conn: sqlite3.Connection, meeting: Meeting, my_names: list[str]) -> None:
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("DELETE FROM meetings WHERE id = ?", (meeting.id,))
    conn.execute(
        "INSERT INTO meetings (id, title, started_at, updated_at, word_count,"
        " filler_count, per_100_words, synced_at, self_speaker)"
        " VALUES (?,?,?,?,0,0,0,?, 'Me')",
        (meeting.id, meeting.title, meeting.started_at, meeting.updated_at, now),
    )
    conn.executemany(
        "INSERT INTO utterances (meeting_id, idx, speaker, text) VALUES (?,?,?,?)",
        [(meeting.id, i, u.speaker, u.text) for i, u in enumerate(meeting.utterances)],
    )
    speaker, result = _analyze_and_store_counts(conn, meeting.id, meeting.utterances, my_names)
    conn.execute(
        "UPDATE meetings SET word_count = ?, filler_count = ?, per_100_words = ?,"
        " self_speaker = ? WHERE id = ?",
        (result.word_count, result.filler_count, result.per_100_words, speaker, meeting.id),
    )


def _reattribute_stored(conn: sqlite3.Connection, my_names: list[str]) -> int:
    """Re-run speaker attribution over already-synced meetings using their
    stored utterances — a new or changed FK_MY_NAME heals history without
    refetching a single transcript."""
    n = 0
    rows = conn.execute("SELECT id, self_speaker FROM meetings").fetchall()
    for row in rows:
        utterances = [
            Utterance(u["speaker"], u["text"])
            for u in conn.execute(
                "SELECT speaker, text FROM utterances WHERE meeting_id = ? ORDER BY idx",
                (row["id"],),
            )
        ]
        if not utterances:
            continue
        if resolve_self_speaker(utterances, my_names) == row["self_speaker"]:
            continue
        speaker, result = _analyze_and_store_counts(conn, row["id"], utterances, my_names)
        conn.execute(
            "UPDATE meetings SET word_count = ?, filler_count = ?, per_100_words = ?,"
            " self_speaker = ? WHERE id = ?",
            (result.word_count, result.filler_count, result.per_100_words, speaker, row["id"]),
        )
        n += 1
    return n
