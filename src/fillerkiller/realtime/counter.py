"""Session state for the real-time listener.

Transcriber-agnostic: whatever engine produces finalized text segments feeds
them to add_final(). Counting only finalized segments prevents double counting
from interim/volatile results. Segments are kept so the dashboard can show a
full session transcript with hits highlighted.
"""

import re
import threading
from dataclasses import dataclass
from datetime import datetime, timezone

from fillerkiller.detector import analyze_text

_WORD_RE = re.compile(r"[A-Za-z']+")


@dataclass
class LiveHit:
    term: str
    category: str
    at: str  # ISO 8601
    segment_idx: int = 0
    start: int = 0
    end: int = 0


class SessionCounter:
    def __init__(self):
        self._lock = threading.Lock()
        self.started_at = datetime.now(timezone.utc).isoformat()
        self.word_count = 0
        self.hits: list[LiveHit] = []
        self.segments: list[tuple[str, str]] = []  # (at, text)

    def add_final(self, text: str) -> list[LiveHit]:
        """Analyze a finalized segment; returns the new hits (for alerts)."""
        now = datetime.now(timezone.utc).isoformat()
        with self._lock:
            idx = len(self.segments)
            found = analyze_text(text, utterance_idx=idx, include_vocalized=True)
            new = [
                LiveHit(h.term, h.category, now, idx, h.start, h.end) for h in found
            ]
            self.segments.append((now, text))
            self.word_count += len(_WORD_RE.findall(text))
            self.hits.extend(new)
        return new

    @property
    def filler_count(self) -> int:
        return len(self.hits)

    @property
    def per_100_words(self) -> float:
        with self._lock:
            if self.word_count == 0:
                return 0.0
            return round(100.0 * len(self.hits) / self.word_count, 2)

    def status_line(self) -> str:
        """Short glanceable summary, used as the menu bar title."""
        return f"FK {self.filler_count} · {self.per_100_words}/100w"

    def persist(self, conn, label: str | None = None) -> int:
        """Write the finished session to SQLite; returns the session id."""
        ended = datetime.now(timezone.utc).isoformat()
        with self._lock:
            cur = conn.execute(
                "INSERT INTO live_sessions (started_at, ended_at, label, word_count,"
                " filler_count, per_100_words) VALUES (?,?,?,?,?,?)",
                (
                    self.started_at,
                    ended,
                    label,
                    self.word_count,
                    len(self.hits),
                    round(100.0 * len(self.hits) / self.word_count, 2)
                    if self.word_count
                    else 0.0,
                ),
            )
            session_id = cur.lastrowid
            conn.executemany(
                "INSERT INTO live_segments (session_id, idx, at, text) VALUES (?,?,?,?)",
                [(session_id, i, at, text) for i, (at, text) in enumerate(self.segments)],
            )
            conn.executemany(
                'INSERT INTO live_hits (session_id, term, category, at, segment_idx,'
                ' start, "end") VALUES (?,?,?,?,?,?,?)',
                [
                    (session_id, h.term, h.category, h.at, h.segment_idx, h.start, h.end)
                    for h in self.hits
                ],
            )
        conn.commit()
        return session_id
