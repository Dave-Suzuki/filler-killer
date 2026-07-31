"""Official Granola API source (public-api.granola.ai).

This is the sanctioned path — and the ONLY path on Granola >= 7.427, which
encrypts all local data (cache-v6.json.enc, SQLCipher granola.db) with a key
readable only by Granola-signed code.

Auth: a `grn_...` API key generated from the Granola desktop app, supplied
via the GRANOLA_API_KEY environment variable. Keys are workspace-scoped and
non-expiring; individuals may need a workspace admin to enable personal API
keys. Read-only access to notes and transcripts.
"""

import json
import urllib.error
import urllib.request

from fillerkiller import config
from fillerkiller.granola.source import Meeting, merge_segments


class PublicApiError(Exception):
    pass


class PublicApiSource:
    def __init__(self, api_key: str | None = None, base: str | None = None, limit: int = 200):
        self.api_key = api_key or config.granola_api_key()
        self.base = (base or config.granola_api_base()).rstrip("/")
        self.limit = limit
        if not self.api_key:
            raise PublicApiError(
                "GRANOLA_API_KEY is not set. Generate an API key in the Granola "
                "desktop app (Settings → API keys; a workspace admin may need to "
                "enable personal API keys), then: export GRANOLA_API_KEY=grn_..."
            )

    def _post(self, endpoint: str, payload: dict) -> dict | list:
        req = urllib.request.Request(
            f"{self.base}/{endpoint.lstrip('/')}",
            data=json.dumps(payload).encode(),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode(errors="replace")[:300]
            except Exception:
                pass
            if e.code in (401, 403):
                raise PublicApiError(
                    f"Granola API rejected the key ({e.code}). Check GRANOLA_API_KEY, "
                    "and that API access is enabled for your workspace/account."
                )
            raise PublicApiError(f"Granola API {endpoint} failed: HTTP {e.code} {body}")
        except Exception as e:
            raise PublicApiError(f"Granola API {endpoint} failed: {e}")

    def ping(self) -> int:
        """Cheap connectivity/auth check; returns how many documents are visible."""
        docs = self._docs(limit=1)
        return len(docs)

    def _docs(self, limit: int) -> list[dict]:
        resp = self._post("get-documents", {"limit": limit, "offset": 0})
        if isinstance(resp, list):
            return resp
        return resp.get("docs") or resp.get("documents") or []

    def meetings(self) -> list[Meeting]:
        out: list[Meeting] = []
        for doc in self._docs(self.limit):
            doc_id = doc.get("id")
            if not doc_id:
                continue
            transcript = self._post("get-document-transcript", {"document_id": doc_id})
            segments = (
                transcript
                if isinstance(transcript, list)
                else transcript.get("transcript") or transcript.get("utterances") or []
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
        out.sort(key=lambda m: m.started_at, reverse=True)
        return out
