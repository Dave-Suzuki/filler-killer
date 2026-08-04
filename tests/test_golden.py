"""Guard the cross-language golden fixtures against oracle drift.

If these fail, either a detector change was unintentional (fix the code) or it
was deliberate — then regenerate with `python3 tools/gen_golden.py`, review the
fixture diff, and update the Swift port to match.
"""

import json
from pathlib import Path

import pytest

from fillerkiller.detector import Utterance, analyze_text, analyze_utterances
from fillerkiller.granola.source import merge_segments

ROOT = Path(__file__).resolve().parent.parent
GOLDEN = json.loads((ROOT / "fixtures" / "detector" / "golden.json").read_text())
MERGE = json.loads((ROOT / "fixtures" / "granola" / "merge.json").read_text())


@pytest.mark.parametrize(
    "case", GOLDEN["text_cases"], ids=[c["name"] for c in GOLDEN["text_cases"]]
)
def test_text_case(case):
    hits = analyze_text(case["text"], include_vocalized=case["include_vocalized"])
    got = [
        {"term": h.term, "category": h.category, "start": h.start, "end": h.end}
        for h in hits
    ]
    assert got == case["expected_hits"]


@pytest.mark.parametrize(
    "case", GOLDEN["utterance_cases"], ids=[c["name"] for c in GOLDEN["utterance_cases"]]
)
def test_utterance_case(case):
    result = analyze_utterances(
        [Utterance(u["speaker"], u["text"]) for u in case["utterances"]],
        speaker=case["speaker"],
        include_vocalized=case["include_vocalized"],
    )
    exp = case["expected"]
    assert result.word_count == exp["word_count"]
    assert result.filler_count == exp["filler_count"]
    assert result.per_100_words == exp["per_100_words"]
    got = [
        {"term": h.term, "category": h.category, "start": h.start, "end": h.end,
         "utterance_idx": h.utterance_idx}
        for h in result.hits
    ]
    assert got == exp["hits"]


@pytest.mark.parametrize(
    "case", MERGE["cases"], ids=[c["name"] for c in MERGE["cases"]]
)
def test_merge_case(case):
    merged = merge_segments(case["segments"])
    got = [{"speaker": u.speaker, "text": u.text} for u in merged]
    assert got == case["expected"]


def test_span_semantics_declared():
    assert GOLDEN["span_semantics"] == "unicode_code_points"
