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
