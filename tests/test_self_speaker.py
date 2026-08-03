"""Self-speaker resolution: "Me" is whoever captured the Granola note, so a
meeting recorded by someone else must count the user's NAMED lines instead of
the note-taker's mic. Regression for the shared-note mis-attribution bug."""

import json
from pathlib import Path

from fillerkiller.detector import Utterance
from fillerkiller.granola.source import Meeting, resolve_self_speaker
from fillerkiller.store.db import connect
from fillerkiller.sync import sync_meetings

GOLDEN = Path(__file__).parent.parent / "fixtures" / "granola" / "self_speaker.json"


def U(pairs):
    return [Utterance(s, t) for s, t in pairs]


def test_no_names_configured_always_me():
    utts = U([("Me", "you know"), ("Dave Suzuki", "so basically")])
    assert resolve_self_speaker(utts, []) == "Me"
    assert resolve_self_speaker(utts, ["  ", ""]) == "Me"


def test_own_note_stays_me():
    utts = U([("Me", "you know"), ("Kelly Schmitt", "agreed")])
    assert resolve_self_speaker(utts, ["Dave Suzuki"]) == "Me"


def test_captured_by_other_matches_named_speaker():
    utts = U([("Me", "like like like"), ("Dave Suzuki", "sounds good")])
    assert resolve_self_speaker(utts, ["Dave Suzuki"]) == "Dave Suzuki"


def test_first_name_matching_both_directions():
    assert resolve_self_speaker(U([("Dave", "hi")]), ["Dave Suzuki"]) == "Dave"
    assert resolve_self_speaker(U([("Dave Suzuki", "hi")]), ["dave"]) == "Dave Suzuki"


def test_me_and_them_labels_never_match_names():
    utts = U([("Me", "hi"), ("Them", "dave suzuki mentioned")])
    assert resolve_self_speaker(utts, ["Dave Suzuki", "Me", "Them"]) == "Me"


def test_most_words_wins_among_multiple_matches():
    utts = U([
        ("Dave", "short"),
        ("Dave Suzuki", "this line clearly has many more words in it"),
    ])
    assert resolve_self_speaker(utts, ["Dave Suzuki"]) == "Dave Suzuki"


def test_golden_fixture_parity():
    golden = json.loads(GOLDEN.read_text())
    assert golden["cases"]
    for case in golden["cases"]:
        utts = [Utterance(u["speaker"], u["text"]) for u in case["utterances"]]
        got = resolve_self_speaker(utts, case["my_names"])
        assert got == case["expected"], f"self-speaker case '{case['name']}'"


class _FakeSource:
    def __init__(self, meetings):
        self._meetings = meetings

    def meetings(self):
        return self._meetings


def _shared_meeting(updated="v1"):
    """A note Prateek captured: his mic is "Me", Dave is a named speaker."""
    return Meeting(
        id="shared-1",
        title="Followup on SLAs",
        started_at="2026-08-03T19:30:00Z",
        updated_at=updated,
        utterances=U([
            ("Me", "Yeah. Like, I think, like, basically it went well. Right?"),
            ("Dave Suzuki", "Sounds good. That's all I wanted to see."),
            ("Kelly Schmitt", "You know, I can basically add that."),
        ]),
    )


def test_sync_counts_named_self_speaker_not_note_taker(tmp_path):
    conn = connect(tmp_path / "fk.db")
    sync_meetings(conn, _FakeSource([_shared_meeting()]), my_names=["Dave Suzuki"])
    row = conn.execute("SELECT * FROM meetings WHERE id = 'shared-1'").fetchone()
    assert row["self_speaker"] == "Dave Suzuki"
    # Dave's clean line: 8 words, zero fillers. Prateek's "like"s don't count.
    assert row["word_count"] == 8
    assert row["filler_count"] == 0
    assert conn.execute("SELECT COUNT(*) c FROM filler_hits").fetchone()["c"] == 0


def test_sync_reattributes_previously_synced_meetings(tmp_path):
    conn = connect(tmp_path / "fk.db")
    # First sync before FK_MY_NAME existed: Prateek's mic counted as Dave.
    stats = sync_meetings(conn, _FakeSource([_shared_meeting()]), my_names=[])
    assert stats["reattributed"] == 0
    row = conn.execute("SELECT * FROM meetings WHERE id = 'shared-1'").fetchone()
    assert row["self_speaker"] == "Me"
    assert row["filler_count"] > 0

    # Name configured later: an unchanged note (skipped by the fetch loop)
    # is healed from its stored utterances, no transcript refetch needed.
    stats = sync_meetings(conn, _FakeSource([_shared_meeting()]), my_names=["Dave Suzuki"])
    assert stats["skipped"] == 1
    assert stats["reattributed"] == 1
    row = conn.execute("SELECT * FROM meetings WHERE id = 'shared-1'").fetchone()
    assert row["self_speaker"] == "Dave Suzuki"
    assert row["filler_count"] == 0
    assert row["word_count"] == 8

    # Steady state: nothing left to heal.
    stats = sync_meetings(conn, _FakeSource([_shared_meeting()]), my_names=["Dave Suzuki"])
    assert stats["reattributed"] == 0


def test_migration_adds_self_speaker_column(tmp_path):
    import sqlite3

    legacy = tmp_path / "old.db"
    conn = sqlite3.connect(legacy)
    conn.execute(
        "CREATE TABLE meetings (id TEXT PRIMARY KEY, title TEXT NOT NULL,"
        " started_at TEXT NOT NULL, updated_at TEXT, word_count INTEGER NOT NULL,"
        " filler_count INTEGER NOT NULL, per_100_words REAL NOT NULL,"
        " synced_at TEXT NOT NULL)"
    )
    conn.execute(
        "INSERT INTO meetings VALUES ('m1', 'Old', '2026-07-01T00:00:00Z',"
        " NULL, 10, 1, 10.0, '2026-07-02T00:00:00Z')"
    )
    conn.commit()
    conn.close()

    migrated = connect(legacy)
    row = migrated.execute("SELECT self_speaker FROM meetings WHERE id = 'm1'").fetchone()
    assert row["self_speaker"] == "Me"
