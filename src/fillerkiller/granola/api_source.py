"""Fallback Granola source: the unofficial HTTP API.

Auth: borrow the CURRENT access token from the local Granola install
(~/Library/Application Support/Granola/supabase.json). We never call the
token-refresh endpoint ourselves — Granola's refresh tokens are one-time-use,
and consuming one would log the desktop app out. The app keeps the access
token fresh; we just re-read the file on every sync.

Unofficial API — endpoints may change. Prefer CacheSource.
"""

import json
import urllib.request
from pathlib import Path

from fillerkiller import config
from fillerkiller.granola.source import Meeting, merge_segments

_API = "https://api.granola.ai"


class ApiError(Exception):
    pass


def _find_access_token(obj) -> str | None:
    """supabase.json is also double-encoded; hunt for access_token at any depth."""
    if isinstance(obj, str):
        try:
            return _find_access_token(json.loads(obj))
        except (json.JSONDecodeError, RecursionError):
            return None
    if isinstance(obj, dict):
        if isinstance(obj.get("access_token"), str):
            return obj["access_token"]
        for v in obj.values():
            token = _find_access_token(v)
            if token:
                return token
    return None


def _read_token(path: Path) -> str:
    try:
        raw = path.read_text()
    except FileNotFoundError:
        raise ApiError(f"Granola auth file not found at {path}")
    token = _find_access_token(raw)
    if not token:
        raise ApiError(f"No access_token found in {path}")
    return token


def _post(endpoint: str, token: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{_API}{endpoint}",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except Exception as e:
        raise ApiError(f"Granola API call {endpoint} failed: {e}")


class ApiSource:
    def __init__(self, supabase_path: Path | None = None, limit: int = 100):
        self.supabase_path = supabase_path or config.granola_supabase_path()
        self.limit = limit

    def meetings(self) -> list[Meeting]:
        token = _read_token(self.supabase_path)
        docs = _post("/v2/get-documents", token, {"limit": self.limit, "offset": 0})
        out: list[Meeting] = []
        for doc in docs.get("docs", []):
            doc_id = doc.get("id")
            if not doc_id:
                continue
            transcript = _post(
                "/v1/get-document-transcript", token, {"document_id": doc_id}
            )
            segments = transcript if isinstance(transcript, list) else transcript.get(
                "transcript", []
            )
            utts = merge_segments(segments)
            if not utts:
                continue
            out.append(
                Meeting(
                    id=str(doc_id),
                    title=doc.get("title") or "(untitled)",
                    started_at=doc.get("created_at") or "",
                    updated_at=doc.get("updated_at"),
                    utterances=utts,
                )
            )
        return out
