from pathlib import Path

import pytest

from fillerkiller.granola.cache_source import CacheParseError, CacheSource

FIXTURE = Path(__file__).parent / "fixtures" / "cache-v3.json"


def test_parses_meetings_newest_first():
    meetings = CacheSource(FIXTURE).meetings()
    assert [m.id for m in meetings] == ["meet-002", "meet-001"]
    assert meetings[1].title == "Weekly 1:1"
    assert meetings[1].updated_at == "2026-07-20T19:05:00Z"


def test_meetings_without_transcripts_skipped():
    ids = {m.id for m in CacheSource(FIXTURE).meetings()}
    assert "meet-no-transcript" not in ids


def test_speaker_mapping_microphone_is_me():
    meeting = [m for m in CacheSource(FIXTURE).meetings() if m.id == "meet-001"][0]
    speakers = [u.speaker for u in meeting.utterances]
    assert speakers == ["Me", "Them", "Me"]


def test_consecutive_same_speaker_segments_merged():
    meeting = [m for m in CacheSource(FIXTURE).meetings() if m.id == "meet-001"][0]
    # Segments 1-3 are all microphone and merge into one utterance, so the
    # "kind of" split across segments 2/3 stays detectable.
    assert "kind of hard to schedule" in meeting.utterances[0].text


def test_missing_file_raises_helpful_error(tmp_path):
    with pytest.raises(CacheParseError, match="not found"):
        CacheSource(tmp_path / "nope.json").meetings()


def test_garbage_file_raises(tmp_path):
    bad = tmp_path / "cache-v3.json"
    bad.write_text("not json at all")
    with pytest.raises(CacheParseError, match="not valid JSON"):
        CacheSource(bad).meetings()
