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


class TestRangesAndRefresh:
    @pytest.fixture
    def fresh_client(self, tmp_path):
        """One recent meeting (now) and one old meeting (2020)."""
        from datetime import datetime, timezone

        from fillerkiller.detector import Utterance
        from fillerkiller.granola.source import Meeting
        from fillerkiller.sync import sync_meetings

        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        meetings = [
            Meeting(id="recent", title="Recent Standup", started_at=now,
                    utterances=[Utterance("Me", "You know, it works.")]),
            Meeting(id="ancient", title="Ancient Kickoff",
                    started_at="2020-01-01T10:00:00Z",
                    utterances=[Utterance("Me", "Basically done.")]),
        ]

        class Src:
            def meetings(self):
                return meetings

        db = tmp_path / "fk.db"
        conn = connect(db)
        sync_meetings(conn, Src())
        conn.close()
        return TestClient(create_app(db, source_factory=Src))

    def test_default_month_range_hides_old(self, fresh_client):
        resp = fresh_client.get("/")
        assert "Recent Standup" in resp.text
        assert "Ancient Kickoff" not in resp.text

    def test_all_range_shows_everything(self, fresh_client):
        resp = fresh_client.get("/?range=all")
        assert "Recent Standup" in resp.text
        assert "Ancient Kickoff" in resp.text

    def test_day_range_and_bad_range_fallback(self, fresh_client):
        assert "Recent Standup" in fresh_client.get("/?range=1d").text
        assert fresh_client.get("/?range=bogus").status_code == 200

    def test_top_fillers_respect_range(self, fresh_client):
        text = fresh_client.get("/?range=1d").text
        assert "you know" in text
        assert "basically" not in text  # only in the ancient meeting

    def test_refresh_endpoint_syncs_and_redirects(self, fresh_client):
        resp = fresh_client.post("/sync?range=7d", follow_redirects=False)
        assert resp.status_code == 303
        assert "range=7d" in resp.headers["location"]
        assert "synced=" in resp.headers["location"]

    def test_refresh_error_redirects_with_message(self, tmp_path):
        class Boom:
            def meetings(self):
                raise RuntimeError("api down")

        db = tmp_path / "fk.db"
        connect(db).close()
        client = TestClient(create_app(db, source_factory=Boom))
        resp = client.post("/sync", follow_redirects=False)
        assert resp.status_code == 303
        assert "sync_error=" in resp.headers["location"]


class TestLiveSessionPage:
    def test_live_page_shows_highlighted_log(self, tmp_path):
        from fillerkiller.realtime.counter import SessionCounter

        db = tmp_path / "fk.db"
        conn = connect(db)
        c = SessionCounter()
        c.add_final("Um so I think this works")
        c.add_final("nothing wrong here")
        sid = c.persist(conn, label="Zoom test")
        conn.close()

        client = TestClient(create_app(db))
        resp = client.get(f"/live/{sid}")
        assert resp.status_code == 200
        assert "Zoom test" in resp.text
        assert '<mark class="cat-vocalized" title="um">Um</mark>' in resp.text
        assert "nothing wrong here" in resp.text

    def test_live_page_404(self, tmp_path):
        db = tmp_path / "fk.db"
        connect(db).close()
        assert TestClient(create_app(db)).get("/live/999").status_code == 404

    def test_index_links_to_live_sessions(self, tmp_path):
        from fillerkiller.realtime.counter import SessionCounter

        db = tmp_path / "fk.db"
        conn = connect(db)
        c = SessionCounter()
        c.add_final("you know the drill")
        sid = c.persist(conn, label="Standup")
        conn.close()
        text = TestClient(create_app(db)).get("/?range=all").text
        assert f'href="/live/{sid}"' in text
