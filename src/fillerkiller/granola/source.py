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
    """Granola marks the note-taker's own speech as microphone/me; everyone
    else comes through system audio. Cache segments carry a flat source field;
    the official API nests it as speaker: {source, attribution}."""
    sp = segment.get("speaker")
    if isinstance(sp, dict):
        if sp.get("attribution") == "me" or sp.get("source") == "microphone":
            return "Me"
        return sp.get("name") or "Them"
    if segment.get("source") == "microphone":
        return "Me"
    return sp or "Them"


def _norm(name: str) -> str:
    return " ".join(name.split()).casefold()


def _name_match(speaker: str, alias: str) -> bool:
    """Match a diarized speaker label against a configured name. Full match,
    or first-name-only on either side ("Dave" label vs "Dave Suzuki" alias
    and vice versa) — Granola labels the same person inconsistently."""
    if speaker == alias:
        return True
    return speaker == alias.split(" ")[0] or speaker.split(" ")[0] == alias


def resolve_self_speaker(utterances: list[Utterance], my_names: list[str]) -> str:
    """Which speaker label is the user in this meeting.

    "Me" is whoever captured the note (their microphone), not necessarily the
    user: shared meetings someone else recorded label THAT person "Me", and
    the user's own words show up under their display name. If a named speaker
    matches one of my_names, count that speaker; otherwise fall back to "Me"
    (the user's own notes, or no names configured)."""
    aliases = [a for a in (_norm(n) for n in my_names) if a]
    if not aliases:
        return "Me"
    words: dict[str, int] = {}
    for u in utterances:
        if u.speaker in ("Me", "Them"):
            continue
        words[u.speaker] = words.get(u.speaker, 0) + len(u.text.split())
    matched = [
        s for s in words if any(_name_match(_norm(s), alias) for alias in aliases)
    ]
    if not matched:
        return "Me"
    # Several labels can match (e.g. "Dave" and "Dave Suzuki"): the one who
    # spoke the most words wins; name breaks exact ties deterministically.
    return max(matched, key=lambda s: (words[s], s))


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
