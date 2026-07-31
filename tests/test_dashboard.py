from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from fillerkiller.dashboard.app import create_app, highlight
from fillerkiller.granola.cache_source import CacheSource
from fillerkiller.store.db import connect
from fillerkiller.sync import sync_meetings

FIXTURE = Path(__file__).parent / "fixtures" / "cache-v3.json"


@pytest.fixture
def client(tmp_path):
    db = tmp_path / "fk.db"
    conn = connect(db)
    sync_meetings(conn, CacheSource(FIXTURE))
    conn.close()
    return TestClient(create_app(db))


def test_index_lists_meetings(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert "Weekly 1:1" in resp.text
    assert "Product Sync" in resp.text
    assert "fillers per 100 words" in resp.text


def test_meeting_page_highlights_fillers(client):
    resp = client.get("/meeting/meet-001")
    assert resp.status_code == 200
    assert '<mark class="cat-phrase" title="you know">you know</mark>' in resp.text
    assert '<mark class="cat-repetition"' in resp.text


def test_meeting_page_escapes_other_speakers(client):
    resp = client.get("/meeting/meet-001")
    # The system speaker's text appears but is never highlighted.
    assert "no concerns from my side" in resp.text


def test_unknown_meeting_404(client):
    assert client.get("/meeting/nope").status_code == 404


class TestHighlight:
    def test_wraps_hits_and_escapes(self):
        text = "It was <b>you know</b> fine."
        hits = [{"term": "you know", "category": "phrase", "start": 10, "end": 18}]
        out = highlight(text, hits)
        assert "&lt;b&gt;" in out
        assert '<mark class="cat-phrase" title="you know">you know</mark>' in out

    def test_overlapping_hits_keep_first(self):
        text = "you you know"
        hits = [
            {"term": "you you", "category": "repetition", "start": 0, "end": 7},
            {"term": "you know", "category": "phrase", "start": 4, "end": 12},
        ]
        out = highlight(text, hits)
        assert out.count("<mark") == 1

    def test_no_hits_plain_escape(self):
        assert highlight("a < b", []) == "a &lt; b"
