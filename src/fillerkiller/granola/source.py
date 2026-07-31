"""GranolaSource protocol: where meetings + transcripts come from.

Implementations:
  CacheSource - reads Granola's local cache-v3.json (primary; zero auth).
  ApiSource   - unofficial api.granola.ai, token borrowed from the local
                Granola install (fallback; never refreshes the token itself).
"""

from dataclasses import dataclass, field
from typing import Protocol

from fillerkiller.detector import Utterance


@dataclass
class Meeting:
    id: str
    title: str
    started_at: str  # ISO 8601
    updated_at: str | None = None
    utterances: list[Utterance] = field(default_factory=list)


class GranolaSource(Protocol):
    def meetings(self) -> list[Meeting]:
        """All available meetings with transcripts, newest first."""
        ...


def _speaker(segment: dict) -> str:
    """Granola attributes segments via source: microphone = the note-taker
    (Me), system = everyone else coming through the speakers."""
    if segment.get("source") == "microphone":
        return "Me"
    return segment.get("speaker") or "Them"


def merge_segments(segments: list) -> list[Utterance]:
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
