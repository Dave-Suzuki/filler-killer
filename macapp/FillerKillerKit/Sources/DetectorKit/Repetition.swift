// Port of src/fillerkiller/detector/repetition.py — the Python file is the
// oracle. Stutter repeats: "I I", "the the", and contraction-prefix repeats
// like "we we're".

// Punctuation between two identical tokens is a clause or sentence boundary
// ("tried it, it worked", "That's it. It works") or a hyphenated double
// ("fifty-fifty") — grammar, not a stutter. Mirrors _BOUNDARY_CHARS.
private let boundaryScalars: Set<Unicode.Scalar> = [
    ".", "!", "?", ",", ";", ":", "…", "—", "–", "-",
]

func findRepetitions(
    _ toks: [Token],
    scalars: [Unicode.Scalar],
    utteranceIdx: Int
) -> [FillerHit] {
    var hits: [FillerHit] = []
    var i = 0
    while i < toks.count - 1 {
        let cur = toks[i]
        let nxt = toks[i + 1]
        if scalars[cur.end ..< nxt.start].contains(where: { boundaryScalars.contains($0) }) {
            i += 1
            continue
        }
        let exact = cur.text == nxt.text && !Wordlist.repetitionAllow.contains(cur.text)
        var prefix = false
        if cur.text != nxt.text,
           !Wordlist.repetitionAllow.contains(cur.text),
           cur.text.unicodeScalars.count >= 2,
           nxt.text.hasPrefix(cur.text) {
            // Require a contraction continuation ("we we're"), not any prefix.
            let rest = nxt.text.dropFirst(cur.text.count)
            prefix = rest.hasPrefix("'")
        }
        if exact || prefix {
            // Both copies capitalized mid-text is a proper noun ("James
            // James"), not a stutter — ASR noise clusters around names.
            // "I" is the one pronoun that's always capitalized; exempt it.
            if cur.text != "i",
               scalars[cur.start].properties.isUppercase,
               scalars[nxt.start].properties.isUppercase {
                i += 1
                continue
            }
            hits.append(FillerHit(
                term: scalarSubstring(scalars, cur.start, nxt.end).lowercased(),
                category: "repetition",
                start: cur.start,
                end: nxt.end,
                utteranceIdx: utteranceIdx
            ))
            i += 2 // don't re-count the second token in an overlapping pair
            continue
        }
        i += 1
    }
    return hits
}
