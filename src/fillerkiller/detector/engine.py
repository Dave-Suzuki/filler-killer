"""Shared filler-detection engine: pure functions, zero I/O.

Used identically by the Granola post-hoc sync and the real-time Deepgram
pipeline. Input is plain text (one utterance) or a list of speaker-labelled
utterances; output is char-span hits plus aggregate stats.
"""

import re
from dataclasses import dataclass, field

from fillerkiller.detector import wordlist
from fillerkiller.detector.repetition import find_repetitions

_TOKEN_RE = re.compile(r"[A-Za-z']+")
_SENTENCE_END = frozenset(".!?")


@dataclass(frozen=True)
class FillerHit:
    term: str  # canonical term, lowercased ("you know", "um", "like", "I I")
    category: str  # vocalized | phrase | discourse | repetition
    start: int  # char offset within the utterance text
    end: int
    utterance_idx: int = 0


@dataclass
class Utterance:
    speaker: str
    text: str


@dataclass
class AnalysisResult:
    hits: list[FillerHit] = field(default_factory=list)
    word_count: int = 0  # words spoken by the analyzed speaker

    @property
    def filler_count(self) -> int:
        return len(self.hits)

    @property
    def per_100_words(self) -> float:
        if self.word_count == 0:
            return 0.0
        return round(100.0 * self.filler_count / self.word_count, 2)

    def counts_by_term(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for h in self.hits:
            out[h.term] = out.get(h.term, 0) + 1
        return dict(sorted(out.items(), key=lambda kv: -kv[1]))

    def counts_by_category(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for h in self.hits:
            out[h.category] = out.get(h.category, 0) + 1
        return out


def _tokens(text: str) -> list[tuple[str, int, int]]:
    """Lowercased word tokens with char spans."""
    return [(m.group(0).lower(), m.start(), m.end()) for m in _TOKEN_RE.finditer(text)]


def _is_sentence_initial(text: str, tok_start: int) -> bool:
    """True if only whitespace/punctuation-that-ends-a-sentence precedes the token."""
    i = tok_start - 1
    while i >= 0:
        ch = text[i]
        if ch.isspace() or ch in "\"'“”‘’,;:-—()":
            i -= 1
            continue
        return ch in _SENTENCE_END
    return True


def analyze_text(
    text: str,
    utterance_idx: int = 0,
    include_vocalized: bool = True,
) -> list[FillerHit]:
    """Detect fillers in a single utterance. Returns hits sorted by position."""
    toks = _tokens(text)
    hits: list[FillerHit] = []
    consumed: set[int] = set()  # token indices claimed by multi-word phrases

    # Multi-word phrases, longest-first so "you know" wins over later scans.
    for phrase in wordlist.PHRASES:
        parts = phrase.split()
        n = len(parts)
        for i in range(len(toks) - n + 1):
            if any(j in consumed for j in range(i, i + n)):
                continue
            if [t[0] for t in toks[i : i + n]] == parts:
                if phrase in ("kind of", "sort of"):
                    prev = toks[i - 1][0] if i > 0 else None
                    if prev in wordlist.KIND_SORT_PREV_BLOCK:
                        continue
                hits.append(
                    FillerHit(phrase, "phrase", toks[i][1], toks[i + n - 1][2], utterance_idx)
                )
                consumed.update(range(i, i + n))

    for i, (word, start, end) in enumerate(toks):
        if i in consumed:
            continue
        prev_word = toks[i - 1][0] if i > 0 else None
        next_word = toks[i + 1][0] if i + 1 < len(toks) else None

        if word in wordlist.VOCALIZED:
            if include_vocalized:
                hits.append(FillerHit(word, "vocalized", start, end, utterance_idx))
        elif word in wordlist.PHRASE_WORDS:
            hits.append(FillerHit(word, "phrase", start, end, utterance_idx))
        elif word == "like":
            if prev_word in wordlist.LIKE_PREV_BLOCK or next_word in wordlist.LIKE_NEXT_BLOCK:
                continue
            hits.append(FillerHit("like", "discourse", start, end, utterance_idx))
        elif word == "so":
            # Vocalized fillers are transparent: "Um, so I think..." is still
            # a sentence-initial "so".
            j = i
            while j > 0 and toks[j - 1][0] in wordlist.VOCALIZED:
                j -= 1
            if not _is_sentence_initial(text, toks[j][1]):
                continue
            if next_word in wordlist.SO_NEXT_BLOCK or next_word is None:
                continue
            hits.append(FillerHit("so", "discourse", start, end, utterance_idx))

    hits.extend(find_repetitions(toks, text, utterance_idx))
    hits.sort(key=lambda h: h.start)
    return hits


def analyze_utterances(
    utterances: list[Utterance],
    speaker: str = "Me",
    include_vocalized: bool = True,
) -> AnalysisResult:
    """Analyze only the given speaker's utterances (default: the note-taker)."""
    result = AnalysisResult()
    for idx, utt in enumerate(utterances):
        if utt.speaker != speaker:
            continue
        result.word_count += len(_tokens(utt.text))
        result.hits.extend(analyze_text(utt.text, idx, include_vocalized))
    return result
