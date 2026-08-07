"""Curated filler terms and the heuristics that guard ambiguous ones.

Categories:
  vocalized  - um/uh/er sounds. Granola's ASR strips these, so they only ever
               appear on the real-time (Deepgram, filler_words=true) path.
  phrase     - unambiguous lexical fillers, matched as whole-word sequences.
  discourse  - "like" and "so": legitimate words that are only fillers in
               certain positions; guarded by heuristics in engine.py.
  repetition - stutter repeats ("I I", "the the", "we we're"); see repetition.py.
"""

VOCALIZED = {"um", "uh", "uhm", "umm", "uhh", "er", "erm", "mhm", "hmm"}

# Multi-word phrases first (matched longest-first), then single words.
PHRASES = [
    "you know",
    "i mean",
    "kind of",
    "sort of",
]
PHRASE_WORDS = {
    "kinda",
    "sorta",
    "basically",
    "literally",
    "actually",
    "honestly",
    "obviously",
}

# "kind of" / "sort of" are classifiers, not hedges, after these ("what kind of car").
KIND_SORT_PREV_BLOCK = {
    "what", "which", "the", "a", "an", "this", "that", "these", "those",
    "any", "some", "every", "one", "each", "no",
}

# "like" is NOT a filler when preceded by these (preference/comparison senses:
# "would like", "looks like", "something like") ...
LIKE_PREV_BLOCK = {
    "would", "i'd", "you'd", "we'd", "they'd", "he'd", "she'd", "'d", "d",
    "don't", "didn't", "doesn't", "won't", "wouldn't", "really", "much",
    "look", "looks", "looked", "looking",
    "feel", "feels", "felt", "feeling",
    "seem", "seems", "seemed",
    "sound", "sounds", "sounded",
    "something", "anything", "nothing", "things", "stuff",
    "just", "not",
}
# ... or when followed by these ("like to", "like that idea").
LIKE_NEXT_BLOCK = {"to", "that", "this", "it", "them", "him", "her", "us", "you"}

# Sentence-initial "so" is the filler usage; skip the handful of legitimate
# sentence-initial continuations ("So far so good").
SO_NEXT_BLOCK = {"far", "long", "much", "many", "what", "that"}

# Consecutive doubles that are usually deliberate ("very very", "no no") or
# ordinary grammar across a clause join with no punctuation to reveal it:
# "I'm sure that that's fine", "I tried it it worked", "we did this this
# morning", "I met her her name is Sam". Deliberate trade-off: a true "that
# that" stutter goes uncounted — missing a rare real stutter beats flagging
# normal speech (field report: false stutters the speaker was sure about).
REPETITION_ALLOW = {
    "very", "really", "no", "yeah", "ha", "bye", "ok", "okay",
    "that", "it", "this", "there", "her",
}
