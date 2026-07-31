"""Official Granola API source (public-api.granola.ai).

This is the sanctioned path — and the ONLY path on Granola >= 7.427, which
encrypts all local data with a key readable only by Granola-signed code.

Verified against the live API (July 2026):
  GET /v1/notes?limit=N          -> {"notes": [...], "cursor": ..., "hasMore": bool}
  GET /v1/notes/{id}?include=transcript
      -> note detail; "transcript" is a list of segments:
         {"text", "start_time", "end_time",
          "speaker": {"source": "microphone"|"system", "attribution": "me"|...}}
      "transcript" is null for meetings still processing (retried next sync).

Auth: a `grn_...` API key generated from the Granola desktop app, supplied via
GRANOLA_API_KEY. Read-only.
"""

import json
import sys
import urllib.error
import urllib.parse
import urllib.request

from fillerkiller import config
from fillerkiller.granola.source import Meeting, merge_segments

_MAX_PAGES = 20


class PublicApiError(Exception):
    pass


class PublicApiSource:
    def __init__(self, api_key: str | None = None, base: str | None = None,
                 page_size: int = 100):
        self.api_key = api_key or config.granola_api_key()
        self.base = (base or config.granola_api_base()).rstrip("/")
        self.page_size = page_size
        self._known: dict[str, str | None] = {}
        if not self.api_key:
            raise PublicApiError(
                "GRANOLA_API_KEY is not set. Generate an API key in the Granola "
                "desktop app (Settings → API keys; a workspace admin may need to "
                "enable personal API keys), then: export GRANOLA_API_KEY=grn_..."
            )

    def set_known(self, known: dict[str, str | None]) -> None:
        """id -> updated_at of already-synced meetings, so unchanged notes
        don't need a transcript fetch (sync passes this in)."""
        self._known = known

    def _get(self, path: str, params: dict | None = None) -> dict | list:
        url = f"{self.base}/{path.lstrip('/')}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {self.api_key}",
                     "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise PublicApiError(
                    f"Granola API rejected the key ({e.code}). Check GRANOLA_API_KEY, "
                    "and that API access is enabled for your workspace/account."
                )
            body = ""
            try:
                body = e.read().decode(errors="replace")[:200]
            except Exception:
                pass
            raise PublicApiError(f"Granola API GET /{path} failed: HTTP {e.code} {body}")
        except Exception as e:
            raise PublicApiError(f"Granola API GET /{path} failed: {e}")

    def ping(self) -> int:
        """Cheap connectivity/auth check; returns how many notes are visible
        on the first page."""
        resp = self._get("notes", {"limit": 1})
        return len(resp.get("notes") or [])

    def _list_notes(self) -> list[dict]:
        notes: list[dict] = []
        cursor: str | None = None
        for _ in range(_MAX_PAGES):
            params: dict = {"limit": self.page_size}
            if cursor:
                params["cursor"] = cursor
            resp = self._get("notes", params)
            page = resp.get("notes") or []
            notes.extend(page)
            next_cursor = resp.get("cursor")
            if not resp.get("hasMore") or not page or not next_cursor or next_cursor == cursor:
                break
            cursor = next_cursor
        return notes

    def meetings(self) -> list[Meeting]:
        listed = self._list_notes()
        out: list[Meeting] = []
        fetched = 0
        for note in listed:
            note_id = note.get("id")
            if not note_id:
                continue
            updated = note.get("updated_at")
            if note_id in self._known and self._known[note_id] == updated:
                # Unchanged since last sync: no transcript fetch needed. Yield a
                # stub so sync's skip-accounting still sees it.
                out.append(Meeting(id=str(note_id), title=note.get("title") or "(untitled)",
                                   started_at=note.get("created_at") or "",
                                   updated_at=updated, utterances=[]))
                continue
            detail = self._get(f"notes/{note_id}", {"include": "transcript"})
            fetched += 1
            if fetched % 20 == 0:
                print(f"  fetched {fetched} transcripts...", file=sys.stderr)
            segments = detail.get("transcript")
            if not segments:
                continue  # still processing; picked up on a later sync
            utts = merge_segments(segments)
            if not utts:
                continue
            out.append(
                Meeting(
                    id=str(note_id),
                    title=detail.get("title") or note.get("title") or "(untitled)",
                    started_at=detail.get("created_at") or note.get("created_at") or "",
                    updated_at=updated,
                    utterances=utts,
                )
            )
        out.sort(key=lambda m: m.started_at, reverse=True)
        return out
