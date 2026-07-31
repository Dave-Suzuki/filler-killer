"""Local web dashboard: trends over time, per-meeting reports, live sessions."""

import html
import json
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from fillerkiller import config
from fillerkiller.store.db import connect

_TEMPLATES = Path(__file__).parent / "templates"


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


def create_app(db_path: Path | None = None) -> FastAPI:
    app = FastAPI(title="filler-killer")
    templates = Jinja2Templates(directory=str(_TEMPLATES))

    def db():
        return connect(db_path or config.db_path())

    @app.get("/", response_class=HTMLResponse)
    def index(request: Request):
        conn = db()
        meetings = conn.execute(
            "SELECT id, title, started_at, word_count, filler_count, per_100_words"
            " FROM meetings WHERE word_count > 0 ORDER BY started_at"
        ).fetchall()
        sessions = conn.execute(
            "SELECT id, started_at, label, word_count, filler_count, per_100_words"
            " FROM live_sessions WHERE ended_at IS NOT NULL AND word_count > 0"
            " ORDER BY started_at"
        ).fetchall()
        top_terms = conn.execute(
            "SELECT term, COUNT(*) AS n FROM filler_hits GROUP BY term"
            " ORDER BY n DESC LIMIT 12"
        ).fetchall()
        chart = {
            "meetings": [
                {"x": m["started_at"][:10], "y": m["per_100_words"], "title": m["title"]}
                for m in meetings
            ],
            "sessions": [
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
            },
        )

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

    return app
