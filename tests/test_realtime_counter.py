"""Replay a realistic sequence of finalized speech segments through the
SessionCounter — this is what the Apple Speech adapter emits on the Mac."""

from fillerkiller.realtime.counter import SessionCounter
from fillerkiller.store.db import connect

SEGMENTS = [
    "Um so I wanted to walk through the plan",
    "it was kind of hard to schedule",
    "I I think we should you know just ship it",
    "the launch date holds",
]


def test_replay_accumulates_counts():
    c = SessionCounter()
    for seg in SEGMENTS:
        c.add_final(seg)
    terms = [h.term for h in c.hits]
    assert "um" in terms  # vocalized counted on the live path
    assert "so" in terms
    assert "kind of" in terms
    assert "i i" in terms
    assert "you know" in terms
    assert c.word_count == 30
    assert c.per_100_words > 0


def test_add_final_returns_new_hits_only():
    c = SessionCounter()
    first = c.add_final("you know the plan")
    second = c.add_final("nothing wrong here")
    assert [h.term for h in first] == ["you know"]
    assert second == []
    assert c.filler_count == 1


def test_status_line_format():
    c = SessionCounter()
    c.add_final("um the plan is set")
    assert c.status_line().startswith("FK 1 ·")


def test_persist_roundtrip(tmp_path):
    conn = connect(tmp_path / "fk.db")
    c = SessionCounter()
    for seg in SEGMENTS:
        c.add_final(seg)
    session_id = c.persist(conn, label="test call")

    row = conn.execute(
        "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
    ).fetchone()
    assert row["label"] == "test call"
    assert row["word_count"] == 30
    assert row["ended_at"] is not None
    n_hits = conn.execute(
        "SELECT COUNT(*) c FROM live_hits WHERE session_id = ?", (session_id,)
    ).fetchone()["c"]
    assert n_hits == c.filler_count


def test_empty_session_persists_zero_rate(tmp_path):
    conn = connect(tmp_path / "fk.db")
    c = SessionCounter()
    session_id = c.persist(conn)
    row = conn.execute(
        "SELECT per_100_words FROM live_sessions WHERE id = ?", (session_id,)
    ).fetchone()
    assert row["per_100_words"] == 0.0
