"""Self-speaker resolution: "Me" is whoever captured the Granola note, so a
meeting recorded by someone else must count the user's NAMED lines instead of
the note-taker's mic. Regression for the shared-note mis-attribution bug."""

import json
from pathlib import Path

from fillerkiller.detector import Utterance
from fillerkiller.granola.source import (
    Meeting,
    extract_owner,
    owned_by_me,
    resolve_self_speaker,
    self_speaker_for,
)
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


def test_extract_owner_shapes():
    assert extract_owner({"owner": {"email": "P@Hiya.com", "name": "Prateek Saxena"}}) == (
        "p@hiya.com", "Prateek Saxena",
    )
    assert extract_owner({"creator": {"name": "Rhonda Simmons"}}) == (None, "Rhonda Simmons")
    assert extract_owner({"created_by": "rhonda.simmons@hiya.com"}) == (
        "rhonda.simmons@hiya.com", None,
    )
    assert extract_owner({"user": "Rhonda Simmons"}) == (None, "Rhonda Simmons")
    assert extract_owner({"title": "no owner here"}) == (None, None)
    assert extract_owner({"owner": {}}) == (None, None)


def test_owned_by_me_decisions():
    # Email is authoritative when both sides have one.
    assert owned_by_me("dave@hiya.com", None, "Dave@Hiya.com", []) is True
    assert owned_by_me("prateek@hiya.com", None, "dave@hiya.com", []) is False
    # Name fallback uses the same matching as speakers.
    assert owned_by_me(None, "Dave", None, ["Dave Suzuki"]) is True
    assert owned_by_me(None, "Rhonda Simmons", None, ["Dave Suzuki"]) is False
    # No usable signal -> unknown.
    assert owned_by_me(None, None, "dave@hiya.com", ["Dave"]) is None
    assert owned_by_me("prateek@hiya.com", None, None, []) is None


def test_self_speaker_for_skips_foreign_notes_without_my_voice():
    utts = U([("Me", "like like basically"), ("Rhonda Simmons", "hola")])
    # Someone else's note, I never speak -> not counted at all.
    assert self_speaker_for(utts, ["Dave Suzuki"], "dave@hiya.com",
                            "rhonda.simmons@hiya.com", "Rhonda Simmons") == ""
    # Someone else's note but I'm a named speaker -> counted as me.
    utts_with_me = utts + U([("Dave Suzuki", "sounds good")])
    assert self_speaker_for(utts_with_me, ["Dave Suzuki"], "dave@hiya.com",
                            "rhonda.simmons@hiya.com", "Rhonda Simmons") == "Dave Suzuki"
    # My own note -> "Me" counted as always.
    assert self_speaker_for(utts, ["Dave Suzuki"], "dave@hiya.com",
                            "dave@hiya.com", "Dave") == "Me"
    # Owner unknown -> unchanged legacy behavior.
    assert self_speaker_for(utts, ["Dave Suzuki"], "dave@hiya.com", None, None) == "Me"


def _foreign_meeting(updated="v1", owner_email="rhonda.simmons@hiya.com"):
    """A note Rhonda captured for a meeting Dave didn't attend."""
    return Meeting(
        id="foreign-1",
        title="Revision de datos",
        started_at="2026-08-01T10:00:00Z",
        updated_at=updated,
        utterances=U([
            ("Me", "so so basically you know"),
            ("Them", "right right"),
        ]),
        owner_email=owner_email,
        owner_name="Rhonda Simmons",
    )


def test_sync_skips_foreign_meeting_entirely(tmp_path):
    conn = connect(tmp_path / "fk.db")
    sync_meetings(conn, _FakeSource([_foreign_meeting()]),
                  my_names=["Dave Suzuki"], my_email="dave.suzuki@hiya.com")
    row = conn.execute("SELECT * FROM meetings WHERE id = 'foreign-1'").fetchone()
    assert row["self_speaker"] == ""
    assert row["word_count"] == 0
    assert row["filler_count"] == 0
    assert row["owner_email"] == "rhonda.simmons@hiya.com"
    assert conn.execute("SELECT COUNT(*) c FROM filler_hits").fetchone()["c"] == 0
    # Transcript still browsable.
    n = conn.execute("SELECT COUNT(*) c FROM utterances WHERE meeting_id='foreign-1'").fetchone()
    assert n["c"] == 2


def test_sync_backfills_owner_and_heals_old_rows(tmp_path):
    conn = connect(tmp_path / "fk.db")
    # Synced before owner metadata existed: counted as Me (the bug).
    no_owner = _foreign_meeting(owner_email=None)
    no_owner.owner_name = None
    sync_meetings(conn, _FakeSource([no_owner]), my_names=["Dave Suzuki"],
                  my_email="dave.suzuki@hiya.com")
    row = conn.execute("SELECT * FROM meetings WHERE id = 'foreign-1'").fetchone()
    assert row["self_speaker"] == "Me"
    assert row["filler_count"] > 0

    # Later sync: note unchanged (stub path) but now carries owner metadata —
    # backfilled, then healed to not-counted.
    stats = sync_meetings(conn, _FakeSource([_foreign_meeting()]),
                          my_names=["Dave Suzuki"], my_email="dave.suzuki@hiya.com")
    assert stats["skipped"] == 1
    assert stats["reattributed"] == 1
    row = conn.execute("SELECT * FROM meetings WHERE id = 'foreign-1'").fetchone()
    assert row["self_speaker"] == ""
    assert row["word_count"] == 0
    assert row["owner_email"] == "rhonda.simmons@hiya.com"


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
