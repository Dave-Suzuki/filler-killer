// Port of src/fillerkiller/detector/engine.py — the Python file is the oracle.
// SPAN SEMANTICS: hit offsets are Unicode SCALAR offsets into the source text
// (matching Python str code-point indices). Tokenization is a hand-rolled
// scanner over unicodeScalars — never regex — to avoid index-space mismatches.

import Foundation

/// Bump when detection RULES change (wordlists, heuristics, repetition
/// logic): stored hits were computed by the version current at analysis
/// time, and the app re-scores its whole history once when this moves.
/// v2: repetition clause-boundary guard + clause-join allowlist.
/// v3: doubled proper nouns ("James James"), intensifiers ("pretty
/// pretty"), and greetings ("hello hello") are not stutters.
public enum DetectorInfo {
    public static let version = 3
}

public struct FillerHit: Equatable, Sendable {
    public let term: String
    public let category: String // vocalized | phrase | discourse | repetition
    public let start: Int // unicode scalar offset
    public let end: Int
    public let utteranceIdx: Int

    public init(term: String, category: String, start: Int, end: Int, utteranceIdx: Int = 0) {
        self.term = term
        self.category = category
        self.start = start
        self.end = end
        self.utteranceIdx = utteranceIdx
    }
}

public struct Utterance: Equatable, Sendable {
    public let speaker: String
    public var text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

public struct AnalysisResult: Equatable, Sendable {
    public var hits: [FillerHit] = []
    public var wordCount: Int = 0

    public init() {}

    public var fillerCount: Int { hits.count }

    /// Matches Python round(x, 2) on this domain: round-half-to-even.
    public var per100Words: Double {
        guard wordCount > 0 else { return 0.0 }
        let raw = 100.0 * Double(hits.count) / Double(wordCount)
        return (raw * 100).rounded(.toNearestOrEven) / 100
    }

    public func countsByTerm() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for h in hits { counts[h.term, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }
}

struct Token {
    let text: String // lowercased
    let start: Int // scalar offset
    let end: Int
}

@inline(__always)
private func isWordScalar(_ s: Unicode.Scalar) -> Bool {
    ("A" ... "Z").contains(s) || ("a" ... "z").contains(s) || s == "'"
}

func tokenize(_ scalars: [Unicode.Scalar]) -> [Token] {
    var tokens: [Token] = []
    var i = 0
    while i < scalars.count {
        if isWordScalar(scalars[i]) {
            let start = i
            var view = String.UnicodeScalarView()
            while i < scalars.count, isWordScalar(scalars[i]) {
                view.append(scalars[i])
                i += 1
            }
            tokens.append(Token(text: String(view).lowercased(), start: start, end: i))
        } else {
            i += 1
        }
    }
    return tokens
}

func scalarSubstring(_ scalars: [Unicode.Scalar], _ start: Int, _ end: Int) -> String {
    var view = String.UnicodeScalarView()
    for s in scalars[start ..< end] { view.append(s) }
    return String(view)
}

private let sentenceEnders: Set<Unicode.Scalar> = [".", "!", "?"]
private let sentenceSkip: Set<Unicode.Scalar> = [
    "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
    ",", ";", ":", "-", "\u{2014}", "(", ")",
]

private func isSentenceInitial(_ scalars: [Unicode.Scalar], _ tokStart: Int) -> Bool {
    var i = tokStart - 1
    while i >= 0 {
        let ch = scalars[i]
        if CharacterSet.whitespacesAndNewlines.contains(ch) || sentenceSkip.contains(ch) {
            i -= 1
            continue
        }
        return sentenceEnders.contains(ch)
    }
    return true
}

/// Detect fillers in a single utterance. Hits sorted by position (stable,
/// matching Python's insertion-order tiebreak).
public func analyzeText(
    _ text: String,
    utteranceIdx: Int = 0,
    includeVocalized: Bool = true
) -> [FillerHit] {
    let scalars = Array(text.unicodeScalars)
    let toks = tokenize(scalars)
    var hits: [FillerHit] = []
    var consumed = Set<Int>()

    // Multi-word phrases, longest-first.
    for phrase in Wordlist.phrases {
        let parts = phrase.split(separator: " ").map(String.init)
        let n = parts.count
        guard toks.count >= n else { continue }
        for i in 0 ... (toks.count - n) {
            if (i ..< (i + n)).contains(where: { consumed.contains($0) }) { continue }
            guard (0 ..< n).allSatisfy({ toks[i + $0].text == parts[$0] }) else { continue }
            if phrase == "kind of" || phrase == "sort of" {
                if i > 0, Wordlist.kindSortPrevBlock.contains(toks[i - 1].text) { continue }
            }
            hits.append(FillerHit(
                term: phrase, category: "phrase",
                start: toks[i].start, end: toks[i + n - 1].end, utteranceIdx: utteranceIdx
            ))
            for j in i ..< (i + n) { consumed.insert(j) }
        }
    }

    for (i, tok) in toks.enumerated() {
        if consumed.contains(i) { continue }
        let prevWord = i > 0 ? toks[i - 1].text : nil
        let nextWord = i + 1 < toks.count ? toks[i + 1].text : nil
        let word = tok.text

        if Wordlist.vocalized.contains(word) {
            if includeVocalized {
                hits.append(FillerHit(
                    term: word, category: "vocalized",
                    start: tok.start, end: tok.end, utteranceIdx: utteranceIdx
                ))
            }
        } else if Wordlist.phraseWords.contains(word) {
            hits.append(FillerHit(
                term: word, category: "phrase",
                start: tok.start, end: tok.end, utteranceIdx: utteranceIdx
            ))
        } else if word == "like" {
            if let p = prevWord, Wordlist.likePrevBlock.contains(p) { continue }
            if let nx = nextWord, Wordlist.likeNextBlock.contains(nx) { continue }
            hits.append(FillerHit(
                term: "like", category: "discourse",
                start: tok.start, end: tok.end, utteranceIdx: utteranceIdx
            ))
        } else if word == "so" {
            // Vocalized fillers are transparent: "Um, so I think..." still
            // counts as a sentence-initial "so".
            var j = i
            while j > 0, Wordlist.vocalized.contains(toks[j - 1].text) { j -= 1 }
            if !isSentenceInitial(scalars, toks[j].start) { continue }
            guard let nx = nextWord else { continue }
            if Wordlist.soNextBlock.contains(nx) { continue }
            hits.append(FillerHit(
                term: "so", category: "discourse",
                start: tok.start, end: tok.end, utteranceIdx: utteranceIdx
            ))
        }
    }

    hits.append(contentsOf: findRepetitions(toks, scalars: scalars, utteranceIdx: utteranceIdx))

    // Stable sort by start (Swift sort stability is unspecified; enforce it).
    return hits.enumerated()
        .sorted { a, b in
            a.element.start != b.element.start
                ? a.element.start < b.element.start
                : a.offset < b.offset
        }
        .map { $0.element }
}

/// Word count using the same tokenizer as detection (parity with Python).
public func wordCount(_ text: String) -> Int {
    tokenize(Array(text.unicodeScalars)).count
}

/// Analyze only the given speaker's utterances (default: the note-taker).
public func analyzeUtterances(
    _ utterances: [Utterance],
    speaker: String = "Me",
    includeVocalized: Bool = true
) -> AnalysisResult {
    var result = AnalysisResult()
    for (idx, utt) in utterances.enumerated() {
        if utt.speaker != speaker { continue }
        result.wordCount += tokenize(Array(utt.text.unicodeScalars)).count
        result.hits.append(contentsOf: analyzeText(
            utt.text, utteranceIdx: idx, includeVocalized: includeVocalized
        ))
    }
    return result
}
