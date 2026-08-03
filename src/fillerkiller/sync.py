"""Pull meetings from a GranolaSource, run the detector, persist to SQLite.

Incremental: a meeting is re-analyzed only if it's new or its updated_at
changed (Granola updates transcripts for a while after a meeting ends).
Vocalized fillers (um/uh) are excluded on this path — Granola's ASR strips
them, so counting them here would just misstate the post-hoc rates.

Speaker attribution: "Me" in a Granola transcript is whoever captured the
note. For shared meetings someone else recorded, the user's own words are
under their display name — self_speaker_for picks the right label per
meeting (FK_MY_NAME), and skips meetings entirely (self_speaker '') when
the note is known to be someone else's (owner metadata + FK_MY_EMAIL) and
the user never speaks. Already-synced meetings are healed from their stored
utterances whenever the resolution changes.
"""

import sqlite3
from datetime import datetime, timezone

from fillerkiller.detector import Utterance, analyze_utterances
from fillerkiller.granola.source import GranolaSource, Meeting, self_speaker_for


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
    conn: sqlite3.Connection,
    source: GranolaSource,
    my_names: list[str] | None = None,
    my_email: str | None = None,
) -> dict:
    from fillerkiller import config

    if my_names is None:
        my_names = config.my_names()
    if my_email is None:
        my_email = config.my_email()
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
                # Unchanged content — but backfill owner metadata (columns
                # added after the meeting was first synced), so the
                # re-attribution pass below can heal it.
                if meeting.owner_email or meeting.owner_name:
                    conn.execute(
                        "UPDATE meetings SET owner_email = COALESCE(owner_email, ?),"
                        " owner_name = COALESCE(owner_name, ?) WHERE id = ?",
                        (meeting.owner_email, meeting.owner_name, meeting.id),
                    )
                skipped += 1
                continue
            updated += 1
        else:
            added += 1
        _store_meeting(conn, meeting, my_names, my_email)
    reattributed = _reattribute_stored(conn, my_names, my_email)
    conn.commit()
    return {
        "added": added,
        "updated": updated,
        "skipped": skipped,
        "reattributed": reattributed,
    }


def _analyze_and_store_counts(
    conn: sqlite3.Connection, meeting_id: str, utterances: list[Utterance],
    speaker: str,
) -> tuple:
    # speaker == "" matches no utterance: zero counts, meeting hidden from
    # trends (queries filter word_count > 0) but transcript stays browsable.
    result = analyze_utterances(utterances, speaker=speaker, include_vocalized=False)
    conn.execute("DELETE FROM filler_hits WHERE meeting_id = ?", (meeting_id,))
    conn.executemany(
        "INSERT INTO filler_hits (meeting_id, utterance_idx, term, category, start, end)"
        " VALUES (?,?,?,?,?,?)",
        [(meeting_id, h.utterance_idx, h.term, h.category, h.start, h.end) for h in result.hits],
    )
    return result


def _store_meeting(
    conn: sqlite3.Connection, meeting: Meeting,
    my_names: list[str], my_email: str | None,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("DELETE FROM meetings WHERE id = ?", (meeting.id,))
    conn.execute(
        "INSERT INTO meetings (id, title, started_at, updated_at, word_count,"
        " filler_count, per_100_words, synced_at, self_speaker, owner_email, owner_name)"
        " VALUES (?,?,?,?,0,0,0,?, 'Me', ?, ?)",
        (meeting.id, meeting.title, meeting.started_at, meeting.updated_at, now,
         meeting.owner_email, meeting.owner_name),
    )
    conn.executemany(
        "INSERT INTO utterances (meeting_id, idx, speaker, text) VALUES (?,?,?,?)",
        [(meeting.id, i, u.speaker, u.text) for i, u in enumerate(meeting.utterances)],
    )
    speaker = self_speaker_for(
        meeting.utterances, my_names, my_email, meeting.owner_email, meeting.owner_name
    )
    result = _analyze_and_store_counts(conn, meeting.id, meeting.utterances, speaker)
    conn.execute(
        "UPDATE meetings SET word_count = ?, filler_count = ?, per_100_words = ?,"
        " self_speaker = ? WHERE id = ?",
        (result.word_count, result.filler_count, result.per_100_words, speaker, meeting.id),
    )


def _reattribute_stored(
    conn: sqlite3.Connection, my_names: list[str], my_email: str | None
) -> int:
    """Re-run speaker attribution over already-synced meetings using their
    stored utterances and owner metadata — a new or changed FK_MY_NAME /
    FK_MY_EMAIL heals history without refetching a single transcript."""
    n = 0
    rows = conn.execute(
        "SELECT id, self_speaker, owner_email, owner_name FROM meetings"
    ).fetchall()
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
        speaker = self_speaker_for(
            utterances, my_names, my_email, row["owner_email"], row["owner_name"]
        )
        if speaker == row["self_speaker"]:
            continue
        result = _analyze_and_store_counts(conn, row["id"], utterances, speaker)
        conn.execute(
            "UPDATE meetings SET word_count = ?, filler_count = ?, per_100_words = ?,"
            " self_speaker = ? WHERE id = ?",
            (result.word_count, result.filler_count, result.per_100_words, speaker, row["id"]),
        )
        n += 1
    return n
