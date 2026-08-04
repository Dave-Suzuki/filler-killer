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
    owner_email: str | None = None  # who captured the note, when the API says
    owner_name: str | None = None


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


def extract_owner(note: dict) -> tuple[str | None, str | None]:
    """Best-effort (email, name) of whoever captured the note, from an API
    payload. The public API exposes the note owner; the key has varied across
    docs, so check the plausible spellings and both shapes (object/string)."""
    for key in ("owner", "creator", "created_by", "user", "author"):
        value = note.get(key)
        if isinstance(value, dict):
            email = value.get("email")
            name = value.get("name") or value.get("full_name") or value.get("display_name")
            if email or name:
                return (
                    str(email).strip().lower() if email else None,
                    str(name).strip() if name else None,
                )
        elif isinstance(value, str) and value.strip():
            raw = value.strip()
            if "@" in raw:
                return raw.lower(), None
            return None, raw
    return None, None


def owned_by_me(
    owner_email: str | None, owner_name: str | None,
    my_email: str | None, my_names: list[str],
) -> bool | None:
    """Did the user capture this note? True/False when the owner metadata
    plus the user's configured identity decide it; None when unknowable."""
    if owner_email and my_email:
        return owner_email.strip().lower() == my_email.strip().lower()
    if owner_name:
        aliases = [a for a in (_norm(n) for n in my_names) if a]
        if aliases:
            return any(_name_match(_norm(owner_name), a) for a in aliases)
    return None


def self_speaker_for(
    utterances: list[Utterance], my_names: list[str], my_email: str | None,
    owner_email: str | None, owner_name: str | None,
) -> str:
    """Which speaker to count, or "" for none. "" happens when the note is
    known to be someone ELSE's and no named speaker matches the user — they
    weren't in the meeting (or never spoke), so counting "Me" would pin the
    note-taker's fillers on them."""
    speaker = resolve_self_speaker(utterances, my_names)
    if speaker == "Me" and owned_by_me(owner_email, owner_name, my_email, my_names) is False:
        return ""
    return speaker


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
