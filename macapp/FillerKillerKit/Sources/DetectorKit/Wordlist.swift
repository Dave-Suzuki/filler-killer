// Port of src/fillerkiller/detector/wordlist.py — keep in lockstep.
// The Python file is the oracle; fixtures/detector/golden.json proves parity.

public enum Wordlist {
    public static let vocalized: Set<String> = [
        "um", "uh", "uhm", "umm", "uhh", "er", "erm", "mhm", "hmm",
    ]

    // Multi-word phrases, matched longest-first.
    public static let phrases: [String] = [
        "you know",
        "i mean",
        "kind of",
        "sort of",
    ]

    public static let phraseWords: Set<String> = [
        "kinda", "sorta", "basically", "literally", "actually",
        "honestly", "obviously",
    ]

    public static let kindSortPrevBlock: Set<String> = [
        "what", "which", "the", "a", "an", "this", "that", "these", "those",
        "any", "some", "every", "one", "each", "no",
    ]

    public static let likePrevBlock: Set<String> = [
        "would", "i'd", "you'd", "we'd", "they'd", "he'd", "she'd", "'d", "d",
        "don't", "didn't", "doesn't", "won't", "wouldn't", "really", "much",
        "look", "looks", "looked", "looking",
        "feel", "feels", "felt", "feeling",
        "seem", "seems", "seemed",
        "sound", "sounds", "sounded",
        "something", "anything", "nothing", "things", "stuff",
        "just", "not",
    ]

    public static let likeNextBlock: Set<String> = [
        "to", "that", "this", "it", "them", "him", "her", "us", "you",
    ]

    public static let soNextBlock: Set<String> = [
        "far", "long", "much", "many", "what", "that",
    ]

    public static let repetitionAllow: Set<String> = [
        "very", "really", "no", "yeah", "ha", "bye", "ok", "okay",
        "that", "it", "this", "there", "her",
        "pretty", "super", "hello", "hi", "hey",
    ]
}
