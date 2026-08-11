"""Stutter-repeat detection: "I I", "the the", and prefix repeats like "we we're".

These survive in Granola transcripts (verified), so they work on both the
post-hoc and real-time paths.
"""

from typing import TYPE_CHECKING

from fillerkiller.detector import wordlist

if TYPE_CHECKING:
    from fillerkiller.detector.engine import FillerHit

_BOUNDARY_CHARS = frozenset(".!?,;:…—–-")


def find_repetitions(
    toks: list[tuple[str, int, int]],
    text: str,
    utterance_idx: int,
) -> list["FillerHit"]:
    from fillerkiller.detector.engine import FillerHit

    hits: list[FillerHit] = []
    i = 0
    while i < len(toks) - 1:
        cur, cur_start, cur_end = toks[i]
        nxt, nxt_start, nxt_end = toks[i + 1]
        # Punctuation between the tokens is a clause or sentence boundary
        # ("tried it, it worked", "That's it. It works") or a hyphenated
        # double ("fifty-fifty") — grammar, not a stutter.
        if any(ch in _BOUNDARY_CHARS for ch in text[cur_end:nxt_start]):
            i += 1
            continue
        exact = cur == nxt and cur not in wordlist.REPETITION_ALLOW
        # Prefix repeat: "we we're", "did didn't". Require a real prefix of a
        # contraction-like continuation, not just any shared letters — and
        # respect the allowlist ("that that's" is ordinary grammar).
        prefix = (
            cur != nxt
            and cur not in wordlist.REPETITION_ALLOW
            and len(cur) >= 2
            and nxt.startswith(cur)
            and nxt[len(cur) :].startswith("'")
        )
        if exact or prefix:
            # Both copies capitalized mid-text is a proper noun ("James
            # James"), not a stutter — ASR noise clusters around names.
            # "I" is the one pronoun that's always capitalized; exempt it.
            if cur != "i" and text[cur_start].isupper() and text[nxt_start].isupper():
                i += 1
                continue
            hits.append(
                FillerHit(
                    term=text[cur_start:nxt_end].lower(),
                    category="repetition",
                    start=cur_start,
                    end=nxt_end,
                    utterance_idx=utterance_idx,
                )
            )
            i += 2  # don't re-count the second token in an overlapping pair
            continue
        i += 1
    return hits
