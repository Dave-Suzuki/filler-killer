from pathlib import Path

from fillerkiller.granola.cache_source import CacheSource
from fillerkiller.store.db import connect
from fillerkiller.sync import sync_meetings

FIXTURE = Path(__file__).parent / "fixtures" / "cache-v3.json"


def _conn(tmp_path):
    return connect(tmp_path / "fk.db")


def test_full_sync_persists_meetings_and_hits(tmp_path):
    conn = _conn(tmp_path)
    stats = sync_meetings(conn, CacheSource(FIXTURE))
    assert stats == {"added": 2, "updated": 0, "skipped": 0}

    row = conn.execute("SELECT * FROM meetings WHERE id = 'meet-001'").fetchone()
    assert row["title"] == "Weekly 1:1"
    assert row["word_count"] > 0
    assert row["per_100_words"] > 0

    terms = {
        r["term"]
        for r in conn.execute("SELECT term FROM filler_hits WHERE meeting_id = 'meet-001'")
    }
    # so (sentence-initial), you know, kind of (merged across segments),
    # i i and we we're (stutters)
    assert {"so", "you know", "kind of", "i i", "we we're"} <= terms


def test_only_me_utterances_counted(tmp_path):
    conn = _conn(tmp_path)
    sync_meetings(conn, CacheSource(FIXTURE))
    # "Basically" from Me counts; nothing from the system speaker does.
    terms = [
        r["term"]
        for r in conn.execute("SELECT term FROM filler_hits WHERE meeting_id = 'meet-002'")
    ]
    assert "basically" in terms
    utt = conn.execute(
        "SELECT speaker FROM utterances WHERE meeting_id = 'meet-002' AND idx = 1"
    ).fetchone()
    assert utt["speaker"] == "Them"  # stored for transcript display, not counted


def test_resync_skips_unchanged(tmp_path):
    conn = _conn(tmp_path)
    sync_meetings(conn, CacheSource(FIXTURE))
    stats = sync_meetings(conn, CacheSource(FIXTURE))
    assert stats == {"added": 0, "updated": 0, "skipped": 2}


def test_updated_meeting_reanalyzed(tmp_path):
    conn = _conn(tmp_path)
    source = CacheSource(FIXTURE)
    sync_meetings(conn, source)
    meetings = source.meetings()

    class Changed:
        def meetings(self):
            for m in meetings:
                if m.id == "meet-001":
                    m.updated_at = "2026-07-20T20:00:00Z"
            return meetings

    stats = sync_meetings(conn, Changed())
    assert stats["updated"] == 1
    assert stats["skipped"] == 1
    # No duplicate rows after re-analysis
    n = conn.execute("SELECT COUNT(*) c FROM meetings WHERE id='meet-001'").fetchone()["c"]
    assert n == 1
