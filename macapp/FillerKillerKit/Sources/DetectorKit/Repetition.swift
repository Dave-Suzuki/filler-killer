// Port of src/fillerkiller/detector/repetition.py — the Python file is the
// oracle. Stutter repeats: "I I", "the the", and contraction-prefix repeats
// like "we we're".

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
        let exact = cur.text == nxt.text && !Wordlist.repetitionAllow.contains(cur.text)
        var prefix = false
        if cur.text != nxt.text,
           cur.text.unicodeScalars.count >= 2,
           nxt.text.hasPrefix(cur.text) {
            // Require a contraction continuation ("we we're"), not any prefix.
            let rest = nxt.text.dropFirst(cur.text.count)
            prefix = rest.hasPrefix("'")
        }
        if exact || prefix {
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
