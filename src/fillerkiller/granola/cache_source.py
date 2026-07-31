"""Primary Granola source: the desktop app's local cache file.

~/Library/Application Support/Granola/cache-v3.json is double-encoded JSON:
an outer envelope whose "cache" value is itself a JSON string containing
{"state": {"documents": {...}, "transcripts": {...}}}. Transcript segments
carry source="microphone" (the note-taker, i.e. Me) or source="system"
(everyone else coming through the speakers).

The format is undocumented and may drift with Granola updates, so parsing is
deliberately defensive: unknown shapes are skipped, never fatal. Verify
against the real file on the Mac (checkpoint 1 in the README).
"""

import json
from pathlib import Path

from fillerkiller import config
from fillerkiller.detector import Utterance
from fillerkiller.granola.source import Meeting


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


def _speaker(segment: dict) -> str:
    source = segment.get("source", "")
    if source == "microphone":
        return "Me"
    return segment.get("speaker") or "Them"


def _utterances(segments: list) -> list[Utterance]:
    """Merge consecutive same-speaker segments so phrases and stutter-repeats
    that span a segment boundary are still detectable."""
    merged: list[Utterance] = []
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        speaker = _speaker(seg)
        if merged and merged[-1].speaker == speaker:
            merged[-1].text += " " + text
        else:
            merged.append(Utterance(speaker, text))
    return merged


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
            utts = _utterances(segments)
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
