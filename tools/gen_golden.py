#!/usr/bin/env python3
"""Regenerate the cross-language golden fixtures from the Python detector.

The Python implementation is the ORACLE: this script runs it over a fixed
corpus and writes the expected outputs that the Swift port (DetectorKit) must
reproduce exactly. Regenerating is a deliberate, reviewed act — if detector
behavior changes on purpose, rerun this and review the fixture diff.

Span semantics: offsets are Unicode CODE POINT offsets into the case text
(Python str indices). Swift must measure in String.unicodeScalars.

Run from the repo root:  python3 tools/gen_golden.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from fillerkiller.detector import Utterance, analyze_text, analyze_utterances  # noqa: E402
from fillerkiller.granola.source import merge_segments, resolve_self_speaker  # noqa: E402

# (name, text, include_vocalized)
TEXT_CASES = [
    # --- vocalized ---
    ("um_uh_basic", "Um, I think, uh, we should go.", True),
    ("vocalized_excluded_posthoc", "Um, I think it works.", False),
    ("no_substring_matches", "The umbrella and the error were ahead.", True),
    ("vocalized_variants", "Erm, hmm, uhh, that's, umm, fine.", True),
    # --- phrases ---
    ("you_know", "It was, you know, pretty hard.", True),
    ("i_mean_kinda", "I mean, it's kinda rough.", True),
    ("kind_of_hedge", "It was kind of difficult.", True),
    ("kind_of_classifier", "What kind of car is that?", True),
    ("kind_of_after_the", "It's the kind of thing we do.", True),
    ("sort_of_hedge", "He was sort of right.", True),
    ("single_word_fillers", "Basically it was literally done.", True),
    ("honestly_obviously", "Honestly, it was obviously fine.", True),
    ("case_insensitive", "You know, Actually, it worked.", True),
    # --- like ---
    ("discourse_like", "It was like really hard.", True),
    ("would_like", "I would like a coffee.", True),
    ("looks_like", "It looks like rain.", True),
    ("like_to", "I like to run.", True),
    ("like_that", "I like that idea.", True),
    ("something_like", "It costs something like $1,300.", True),
    ("feels_like", "It feels like winter.", True),
    ("dont_like", "I don't like it.", True),
    ("just_like", "It was just like last time.", True),
    ("double_like", "It was like, like, impossible.", True),
    # --- so ---
    ("sentence_initial_so", "So we decided to ship it.", True),
    ("mid_sentence_so", "It was so good we stayed.", True),
    ("so_after_period", "We shipped. So the next step is QA.", True),
    ("so_far", "So far it works.", True),
    ("so_after_comma", "Yes, so basically done.", True),
    ("um_so_transparency", "Um, so I wanted to walk through the plan.", True),
    ("um_uh_so_chain", "Um, uh, so we begin.", True),
    ("um_so_vocalized_excluded", "Um, so I wanted to walk through the plan.", False),
    ("so_at_utterance_end", "I think so.", True),
    ("so_after_question", "Really? So what happened next?", True),
    ("quoted_so", "“So we begin.”", True),
    ("so_after_dash", "Right — so the plan holds.", True),
    # --- repetition ---
    ("exact_repeats", "I I think the the plan works.", True),
    ("prefix_contraction", "we we're very understanding", True),
    ("allowed_doubles", "It was very very good. No no, really.", True),
    ("triple_repeat", "that that that", True),
    ("quadruple_repeat", "go go go go", True),
    ("repeat_case_mix", "The the plan and We we're set.", True),
    # --- unicode / adversarial ---
    ("curly_apostrophe_token_split", "we we’re very understanding", True),
    ("emoji_offsets", "I \U0001f600 think, you know, it's fine.", True),
    ("cjk_mixed", "次も終わり you know です", True),
    ("newlines_and_tabs", "So\n\twe, you know,\nship it.", True),
    ("empty_text", "", True),
    ("only_punctuation", "?! ... —", True),
    ("apostrophe_only_tokens", "'' ' ''", True),
    # --- overlap ---
    ("phrase_repetition_overlap", "you you know the drill", True),
    ("kind_of_kind_of", "kind of kind of works", True),
    # --- realistic granola-style ---
    (
        "granola_excerpt",
        "And I know you you know, generally try to make sense better. "
        "The the reason is, like, as Chelsea touched upon, we keep having "
        "the consistent challenging feedback.",
        True,
    ),
    (
        "live_style_segment",
        "Um so I wanted to walk through the plan it was kind of hard to schedule",
        True,
    ),
]

# (name, utterances, speaker, include_vocalized)
UTTERANCE_CASES = [
    (
        "me_only_filtering",
        [
            ("Me", "You know, I think it works."),
            ("Chelsea", "You know what I mean, basically."),
            ("Me", "It was kind of hard."),
        ],
        "Me",
        False,
    ),
    (
        "bankers_rounding_3125",
        # 1 hit ("you know") in 32 words -> 3.125 -> Python round() = 3.12
        [(
            "Me",
            "you know alpha bravo charlie delta echo foxtrot golf hotel india "
            "juliet kilo lima mike november oscar papa quebec romeo sierra "
            "tango uniform victor whiskey xray yankee zulu green blue red gold",
        )],
        "Me",
        True,
    ),
    (
        "bankers_rounding_9375",
        # 3 hits in 32 words -> 9.375 -> Python round() = 9.38 (round-half-even
        # rounds UP here because 9.37 is odd; pairs with the 3.12 case above)
        [(
            "Me",
            "um you know like alpha bravo charlie delta echo foxtrot golf "
            "hotel india juliet kilo lima mike november oscar papa quebec "
            "romeo sierra tango uniform victor whiskey xray yankee zulu green blue",
        )],
        "Me",
        True,
    ),
    ("empty", [], "Me", True),
    (
        "multi_utterance_indices",
        [
            ("Me", "So the plan holds."),
            ("Them", "so basically fine"),
            ("Me", "It was kind of, you know, fine."),
        ],
        "Me",
        True,
    ),
]

# Granola segment-merge cases: each is (name, segments_json)
MERGE_CASES = [
    (
        "nested_speaker_attribution_me",
        [
            {"text": "So basically we", "speaker": {"source": "microphone", "attribution": "me"}},
            {"text": "should ship it.", "speaker": {"source": "microphone", "attribution": "me"}},
            {"text": "Agreed.", "speaker": {"source": "system", "attribution": "them"}},
        ],
    ),
    (
        "flat_source_shape",
        [
            {"text": "I I think we're aligned.", "source": "microphone"},
            {"text": "Sounds good.", "source": "system"},
            {"text": "Great.", "source": "system"},
        ],
    ),
    (
        "named_speaker_nested",
        [
            {"text": "Hello there.", "speaker": {"source": "system", "name": "Prateek"}},
            {"text": "Hi.", "speaker": {"source": "microphone", "attribution": "me"}},
        ],
    ),
    (
        "flat_named_speaker_string",
        [
            {"text": "Hello.", "source": "system", "speaker": "Chelsea"},
            {"text": "More.", "source": "system", "speaker": "Chelsea"},
        ],
    ),
    (
        "empty_and_whitespace_segments_skipped",
        [
            {"text": "  ", "source": "microphone"},
            {"text": "Real text.", "source": "microphone"},
            {"text": "", "source": "system"},
            {"text": None, "source": "system"},
        ],
    ),
    (
        "merge_across_boundary_enables_phrase",
        [
            {"text": "It was kind of", "source": "microphone"},
            {"text": "hard to schedule.", "source": "microphone"},
        ],
    ),
    ("not_a_dict_segment_skipped", [{"text": "ok", "source": "microphone"}, "garbage", 42]),
]

# Self-speaker resolution cases: (name, utterances, my_names). "Me" is the
# note-taker, so in a meeting captured by someone else the user is a NAMED
# speaker — these pin which label gets counted.
SELF_SPEAKER_CASES = [
    (
        "no_names_configured_stays_me",
        [("Me", "you know it works"), ("Dave Suzuki", "so basically fine")],
        [],
    ),
    (
        "own_note_no_named_match_stays_me",
        [("Me", "you know it works"), ("Kelly Schmitt", "agreed")],
        ["Dave Suzuki"],
    ),
    (
        "captured_by_other_full_name_match",
        [("Me", "like like a lot of fillers"), ("Dave Suzuki", "sounds good")],
        ["Dave Suzuki"],
    ),
    (
        "first_name_label_matches_full_alias",
        [("Me", "yep yep yep"), ("Dave", "I can hear you")],
        ["Dave Suzuki"],
    ),
    (
        "full_label_matches_first_name_alias",
        [("Me", "so so so"), ("Dave Suzuki", "okay good")],
        ["dave"],
    ),
    (
        "case_and_whitespace_insensitive",
        [("Me", "right right"), ("Dave  Suzuki", "yes")],
        ["  DAVE   SUZUKI "],
    ),
    (
        "most_words_wins_among_matches",
        [
            ("Me", "hello"),
            ("Dave", "short line"),
            ("Dave Suzuki", "this longer line has the most words here"),
        ],
        ["Dave Suzuki", "Dave"],
    ),
    (
        "them_never_matches",
        [("Me", "hi"), ("Them", "dave suzuki said something")],
        ["Dave Suzuki"],
    ),
]


def hit_dict(h):
    return {
        "term": h.term,
        "category": h.category,
        "start": h.start,
        "end": h.end,
        "utterance_idx": h.utterance_idx,
    }


def main() -> None:
    detector = {
        "version": 1,
        "span_semantics": "unicode_code_points",
        "text_cases": [
            {
                "name": name,
                "text": text,
                "include_vocalized": iv,
                "expected_hits": [
                    {k: v for k, v in hit_dict(h).items() if k != "utterance_idx"}
                    for h in analyze_text(text, include_vocalized=iv)
                ],
            }
            for name, text, iv in TEXT_CASES
        ],
        "utterance_cases": [],
    }
    for name, utts, speaker, iv in UTTERANCE_CASES:
        result = analyze_utterances(
            [Utterance(s, t) for s, t in utts], speaker=speaker, include_vocalized=iv
        )
        detector["utterance_cases"].append(
            {
                "name": name,
                "utterances": [{"speaker": s, "text": t} for s, t in utts],
                "speaker": speaker,
                "include_vocalized": iv,
                "expected": {
                    "word_count": result.word_count,
                    "filler_count": result.filler_count,
                    "per_100_words": result.per_100_words,
                    "hits": [hit_dict(h) for h in result.hits],
                },
            }
        )

    merge = {
        "version": 1,
        "cases": [
            {
                "name": name,
                "segments": segments,
                "expected": [
                    {"speaker": u.speaker, "text": u.text}
                    for u in merge_segments(segments)
                ],
            }
            for name, segments in MERGE_CASES
        ],
    }

    self_speaker = {
        "version": 1,
        "cases": [
            {
                "name": name,
                "utterances": [{"speaker": s, "text": t} for s, t in utts],
                "my_names": my_names,
                "expected": resolve_self_speaker(
                    [Utterance(s, t) for s, t in utts], my_names
                ),
            }
            for name, utts, my_names in SELF_SPEAKER_CASES
        ],
    }

    out_detector = ROOT / "fixtures" / "detector" / "golden.json"
    out_merge = ROOT / "fixtures" / "granola" / "merge.json"
    out_self = ROOT / "fixtures" / "granola" / "self_speaker.json"
    out_detector.parent.mkdir(parents=True, exist_ok=True)
    out_merge.parent.mkdir(parents=True, exist_ok=True)
    out_detector.write_text(json.dumps(detector, indent=1, ensure_ascii=False) + "\n")
    out_merge.write_text(json.dumps(merge, indent=1, ensure_ascii=False) + "\n")
    out_self.write_text(json.dumps(self_speaker, indent=1, ensure_ascii=False) + "\n")
    n_hits = sum(len(c["expected_hits"]) for c in detector["text_cases"])
    print(
        f"wrote {len(detector['text_cases'])} text cases ({n_hits} hits), "
        f"{len(detector['utterance_cases'])} utterance cases, "
        f"{len(merge['cases'])} merge cases, "
        f"{len(self_speaker['cases'])} self-speaker cases"
    )


if __name__ == "__main__":
    main()
