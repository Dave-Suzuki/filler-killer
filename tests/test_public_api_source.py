"""Fixtures mirror the live public-api.granola.ai responses verified July 2026:
GET /v1/notes -> {notes, cursor, hasMore}; GET /v1/notes/{id}?include=transcript
-> detail whose transcript segments nest speaker: {source, attribution}."""

import pytest

from fillerkiller.granola.public_api_source import PublicApiError, PublicApiSource

NOTES_PAGE_1 = {
    "notes": [
        {"id": "not_a", "object": "note", "title": "Sync",
         "created_at": "2026-07-30T10:00:00Z", "updated_at": "2026-07-30T11:00:00Z"},
        {"id": "not_b", "object": "note", "title": "Processing",
         "created_at": "2026-07-31T10:00:00Z", "updated_at": "2026-07-31T10:30:00Z"},
    ],
    "cursor": "cur_1",
    "hasMore": True,
}
NOTES_PAGE_2 = {
    "notes": [
        {"id": "not_c", "object": "note", "title": "Old 1:1",
         "created_at": "2026-07-29T10:00:00Z", "updated_at": "2026-07-29T11:00:00Z"},
    ],
    "cursor": None,
    "hasMore": False,
}
DETAILS = {
    "not_a": {
        "id": "not_a", "title": "Sync", "created_at": "2026-07-30T10:00:00Z",
        "transcript": [
            {"text": "So basically we", "start_time": "t1", "end_time": "t2",
             "speaker": {"source": "microphone", "attribution": "me"}},
            {"text": "should ship it, you know.", "start_time": "t2", "end_time": "t3",
             "speaker": {"source": "microphone", "attribution": "me"}},
            {"text": "Agreed.", "start_time": "t3", "end_time": "t4",
             "speaker": {"source": "system", "attribution": "them"}},
        ],
    },
    "not_b": {"id": "not_b", "title": "Processing", "transcript": None},
    "not_c": {
        "id": "not_c", "title": "Old 1:1", "created_at": "2026-07-29T10:00:00Z",
        "transcript": [
            {"text": "I mean, fine.", "start_time": "t1", "end_time": "t2",
             "speaker": {"source": "microphone", "attribution": "me"}},
        ],
    },
}


def _source(monkeypatch):
    src = PublicApiSource(api_key="grn_test")
    calls = []

    def fake_get(path, params=None):
        calls.append((path, params or {}))
        if path == "notes":
            return NOTES_PAGE_2 if (params or {}).get("cursor") == "cur_1" else NOTES_PAGE_1
        assert path.startswith("notes/")
        assert (params or {}).get("include") == "transcript"
        return DETAILS[path.split("/")[1]]

    monkeypatch.setattr(src, "_get", fake_get)
    return src, calls


def test_requires_api_key(monkeypatch):
    monkeypatch.delenv("GRANOLA_API_KEY", raising=False)
    with pytest.raises(PublicApiError, match="GRANOLA_API_KEY"):
        PublicApiSource()


def test_paginates_and_parses(monkeypatch):
    src, calls = _source(monkeypatch)
    meetings = src.meetings()
    # not_b has a null transcript (still processing) and is omitted entirely.
    assert [m.id for m in meetings] == ["not_a", "not_c"]
    note_pages = [c for c in calls if c[0] == "notes"]
    assert len(note_pages) == 2  # followed the cursor


def test_speaker_attribution_and_merge(monkeypatch):
    src, _ = _source(monkeypatch)
    m = [m for m in src.meetings() if m.id == "not_a"][0]
    assert m.utterances[0].speaker == "Me"
    assert m.utterances[0].text == "So basically we should ship it, you know."
    assert m.utterances[1].speaker == "Them"


def test_known_unchanged_notes_skip_transcript_fetch(monkeypatch):
    src, calls = _source(monkeypatch)
    src.set_known({"not_a": "2026-07-30T11:00:00Z"})  # matches -> stub, no fetch
    meetings = src.meetings()
    stub = [m for m in meetings if m.id == "not_a"][0]
    assert stub.utterances == []
    assert not any(c[0] == "notes/not_a" for c in calls)
    # Changed/unknown notes are still fetched.
    assert any(c[0] == "notes/not_c" for c in calls)


def test_sync_integration_incremental(monkeypatch, tmp_path):
    from fillerkiller.store.db import connect
    from fillerkiller.sync import sync_meetings

    conn = connect(tmp_path / "fk.db")
    src, _ = _source(monkeypatch)
    assert sync_meetings(conn, src) == {"added": 2, "updated": 0, "skipped": 0}

    src2, calls2 = _source(monkeypatch)
    assert sync_meetings(conn, src2) == {"added": 0, "updated": 0, "skipped": 2}
    # Second sync refetched nothing already stored; only the still-processing
    # note (not_b, never persisted) is retried.
    assert not any(c[0] in ("notes/not_a", "notes/not_c") for c in calls2)
    assert any(c[0] == "notes/not_b" for c in calls2)
