"""Local web dashboard: trends over time, per-meeting reports, live sessions."""

import html
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from fillerkiller import config
from fillerkiller.store.db import connect

_TEMPLATES = Path(__file__).parent / "templates"

# label -> rolling window in days (None = everything)
RANGES = {"1d": 1, "3d": 3, "7d": 7, "30d": 30, "all": None}
RANGE_LABELS = {"1d": "Day", "3d": "3 days", "7d": "Week", "30d": "Month", "all": "All"}
DEFAULT_RANGE = "30d"


def _cutoff(range_key: str) -> str | None:
    days = RANGES.get(range_key, RANGES[DEFAULT_RANGE])
    if days is None:
        return None
    # Bare "YYYY-MM-DDTHH:MM:SS" prefix compares lexicographically against
    # both Granola's "...Z" stamps and our own isoformat() stamps.
    return (datetime.now(timezone.utc) - timedelta(days=days)).strftime(
        "%Y-%m-%dT%H:%M:%S"
    )


def highlight(text: str, hits: list[dict]) -> str:
    """Escape utterance text and wrap each hit span in a <mark> tag."""
    out: list[str] = []
    pos = 0
    for h in sorted(hits, key=lambda h: h["start"]):
        start, end = h["start"], h["end"]
        if start < pos:  # overlapping hit (phrase + repetition can share text)
            continue
        out.append(html.escape(text[pos:start]))
        out.append(
            f'<mark class="cat-{html.escape(h["category"])}" '
            f'title="{html.escape(h["term"])}">{html.escape(text[start:end])}</mark>'
        )
        pos = end
    out.append(html.escape(text[pos:]))
    return "".join(out)


def create_app(db_path: Path | None = None, source_factory=None) -> FastAPI:
    app = FastAPI(title="filler-killer")
    templates = Jinja2Templates(directory=str(_TEMPLATES))

    if source_factory is None:
        from fillerkiller.sync import default_source as source_factory

    def db():
        return connect(db_path or config.db_path())

    @app.get("/", response_class=HTMLResponse)
    def index(request: Request, range: str = DEFAULT_RANGE,
              synced: str | None = None, sync_error: str | None = None):
        if range not in RANGES:
            range = DEFAULT_RANGE
        cutoff = _cutoff(range)
        since = f" AND started_at >= '{cutoff}'" if cutoff else ""
        conn = db()
        meetings = conn.execute(
            "SELECT id, title, started_at, word_count, filler_count, per_100_words"
            f" FROM meetings WHERE word_count > 0{since} ORDER BY started_at"
        ).fetchall()
        sessions = conn.execute(
            "SELECT id, started_at, label, word_count, filler_count, per_100_words"
            " FROM live_sessions WHERE ended_at IS NOT NULL AND word_count > 0"
            f"{since} ORDER BY started_at"
        ).fetchall()
        top_terms = conn.execute(
            "SELECT term, COUNT(*) AS n FROM filler_hits WHERE meeting_id IN"
            f" (SELECT id FROM meetings WHERE word_count > 0{since})"
            " GROUP BY term ORDER BY n DESC LIMIT 12"
        ).fetchall()
        def daily(rows):
            """One point per day: rate weighted by words spoken that day."""
            agg: dict[str, list[int]] = {}
            for r in rows:
                day = r["started_at"][:10]
                a = agg.setdefault(day, [0, 0, 0])
                a[0] += r["filler_count"]
                a[1] += r["word_count"]
                a[2] += 1
            return [
                {"x": day, "y": round(100.0 * f / w, 2), "n": n}
                for day, (f, w, n) in sorted(agg.items())
                if w
            ]

        days = sorted(
            {m["started_at"][:10] for m in meetings}
            | {s["started_at"][:10] for s in sessions}
        )
        chart = {
            "labels": days,
            "meetings_daily": daily(meetings),
            "meetings_points": [
                {"x": m["started_at"][:10], "y": m["per_100_words"], "title": m["title"]}
                for m in meetings
            ],
            "sessions_daily": daily(sessions),
            "sessions_points": [
                {"x": s["started_at"][:10], "y": s["per_100_words"],
                 "title": s["label"] or f"Live session {s['id']}"}
                for s in sessions
            ],
            "terms": {"labels": [t["term"] for t in top_terms],
                      "counts": [t["n"] for t in top_terms]},
        }
        total_words = sum(m["word_count"] for m in meetings)
        total_fillers = sum(m["filler_count"] for m in meetings)
        overall = round(100 * total_fillers / total_words, 2) if total_words else 0.0
        conn.close()
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "meetings": list(reversed(meetings)),
                "sessions": list(reversed(sessions)),
                "chart_json": json.dumps(chart),
                "overall": overall,
                "total_fillers": total_fillers,
                "meeting_count": len(meetings),
                "range": range,
                "range_labels": RANGE_LABELS,
                "synced": synced,
                "sync_error": sync_error,
            },
        )

    @app.post("/sync")
    def sync(range: str = DEFAULT_RANGE):
        from urllib.parse import quote

        from fillerkiller.sync import sync_meetings

        conn = db()
        try:
            stats = sync_meetings(conn, source_factory())
        except Exception as e:
            return RedirectResponse(
                f"/?range={range}&sync_error={quote(str(e)[:200])}", status_code=303
            )
        finally:
            conn.close()
        msg = quote(f"{stats['added']} new, {stats['updated']} updated")
        return RedirectResponse(f"/?range={range}&synced={msg}", status_code=303)

    @app.get("/meeting/{meeting_id}", response_class=HTMLResponse)
    def meeting(request: Request, meeting_id: str):
        conn = db()
        m = conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
        if m is None:
            conn.close()
            raise HTTPException(404, "meeting not found")
        utts = conn.execute(
            "SELECT idx, speaker, text FROM utterances WHERE meeting_id = ? ORDER BY idx",
            (meeting_id,),
        ).fetchall()
        hits = [
            dict(r)
            for r in conn.execute(
                "SELECT utterance_idx, term, category, start, end FROM filler_hits"
                " WHERE meeting_id = ?",
                (meeting_id,),
            )
        ]
        conn.close()
        by_utt: dict[int, list[dict]] = {}
        for h in hits:
            by_utt.setdefault(h["utterance_idx"], []).append(h)
        transcript = [
            {
                "speaker": u["speaker"],
                "html": highlight(u["text"], by_utt.get(u["idx"], []))
                if u["speaker"] == "Me"
                else html.escape(u["text"]),
            }
            for u in utts
        ]
        term_counts: dict[str, int] = {}
        for h in hits:
            term_counts[h["term"]] = term_counts.get(h["term"], 0) + 1
        return templates.TemplateResponse(
            request,
            "meeting.html",
            {
                "m": m,
                "transcript": transcript,
                "term_counts": sorted(term_counts.items(), key=lambda kv: -kv[1]),
            },
        )

    @app.get("/live/{session_id}", response_class=HTMLResponse)
    def live_session(request: Request, session_id: int):
        conn = db()
        s = conn.execute(
            "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
        ).fetchone()
        if s is None:
            conn.close()
            raise HTTPException(404, "session not found")
        segments = conn.execute(
            "SELECT idx, at, text FROM live_segments WHERE session_id = ? ORDER BY idx",
            (session_id,),
        ).fetchall()
        hits = [
            dict(r)
            for r in conn.execute(
                'SELECT segment_idx, term, category, start, "end" FROM live_hits'
                " WHERE session_id = ?",
                (session_id,),
            )
        ]
        conn.close()
        by_seg: dict[int, list[dict]] = {}
        for h in hits:
            by_seg.setdefault(h["segment_idx"], []).append(h)
        transcript = [
            {
                "at": seg["at"][11:19],  # HH:MM:SS
                "html": highlight(seg["text"], by_seg.get(seg["idx"], [])),
            }
            for seg in segments
        ]
        term_counts: dict[str, int] = {}
        for h in hits:
            term_counts[h["term"]] = term_counts.get(h["term"], 0) + 1
        return templates.TemplateResponse(
            request,
            "live.html",
            {
                "s": s,
                "transcript": transcript,
                "term_counts": sorted(term_counts.items(), key=lambda kv: -kv[1]),
            },
        )

    return app
