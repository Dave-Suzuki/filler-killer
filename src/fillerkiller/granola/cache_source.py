"""Primary Granola source: the desktop app's local cache file.

Handles both historical shapes:
- cache-v3.json: double-encoded — the outer "cache" value is itself a JSON
  string containing {"state": {"documents": ..., "transcripts": ...}}.
- cache-v6.json: single-encoded — "cache" is a plain object with the same
  state shape.

Granola >= 7.427 encrypts the cache (cache-v6.json.enc) with a key only
Granola-signed code can read — on those installs use PublicApiSource
(GRANOLA_API_KEY) instead; fk doctor detects this and says so.

The format is undocumented and may drift with Granola updates, so parsing is
deliberately defensive: unknown shapes are skipped, never fatal. Verify
against the real file on the Mac (checkpoint 1 in the README).
"""

import json
from pathlib import Path

from fillerkiller import config
from fillerkiller.granola.source import Meeting, merge_segments


class CacheParseError(Exception):
    pass


def _load_state(path: Path) -> dict:
    try:
        outer = json.loads(path.read_text())
    except FileNotFoundError:
        raise CacheParseError(
            f"Granola cache not found at {path}. Is Granola installed? "
            "(Override with FK_GRANOLA_CACHE.)"
        )
    except json.JSONDecodeError as e:
        raise CacheParseError(f"Granola cache is not valid JSON: {e}")

    inner = outer.get("cache", outer) if isinstance(outer, dict) else outer
    if isinstance(inner, str):  # the double-encoding step
        try:
            inner = json.loads(inner)
        except json.JSONDecodeError as e:
            raise CacheParseError(f"Granola inner cache is not valid JSON: {e}")
    if not isinstance(inner, dict):
        raise CacheParseError("Unexpected Granola cache shape (no state dict)")
    state = inner.get("state", inner)
    if not isinstance(state, dict):
        raise CacheParseError("Unexpected Granola cache shape (state is not a dict)")
    return state


class CacheSource:
    def __init__(self, path: Path | None = None):
        self.path = path or config.granola_cache_path()

    def meetings(self) -> list[Meeting]:
        state = _load_state(self.path)
        documents = state.get("documents") or {}
        transcripts = state.get("transcripts") or {}
        if not isinstance(documents, dict) or not isinstance(transcripts, dict):
            raise CacheParseError("Unexpected Granola cache shape (documents/transcripts)")

        out: list[Meeting] = []
        for doc_id, doc in documents.items():
            if not isinstance(doc, dict):
                continue
            segments = transcripts.get(doc_id)
            if not segments:
                continue  # meetings without transcripts can't be analyzed
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
