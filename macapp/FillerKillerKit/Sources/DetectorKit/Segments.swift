// Port of merge_segments / _speaker from src/fillerkiller/granola/source.py.
// Handles both Granola transcript shapes: the official API's nested
// speaker: {source, attribution, name} and the legacy flat source field.

import Foundation

public struct RawSegment: Sendable {
    public let text: String?
    public let source: String?
    public let speakerName: String? // flat string speaker
    public let speakerObject: SpeakerObject?

    public struct SpeakerObject: Sendable {
        public let source: String?
        public let attribution: String?
        public let name: String?

        public init(source: String?, attribution: String?, name: String?) {
            self.source = source
            self.attribution = attribution
            self.name = name
        }
    }

    public init(text: String?, source: String? = nil,
                speakerName: String? = nil, speakerObject: SpeakerObject? = nil) {
        self.text = text
        self.source = source
        self.speakerName = speakerName
        self.speakerObject = speakerObject
    }
}

extension RawSegment: Decodable {
    private enum CodingKeys: String, CodingKey {
        case text, source, speaker
    }

    private struct SpeakerObjectPayload: Decodable {
        let source: String?
        let attribution: String?
        let name: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        // try? flattens the decodeIfPresent double optional (SE-0230), so
        // `obj` binds fully unwrapped here.
        if let obj = try? container.decodeIfPresent(SpeakerObjectPayload.self, forKey: .speaker) {
            speakerObject = SpeakerObject(
                source: obj.source, attribution: obj.attribution, name: obj.name
            )
            speakerName = nil
        } else {
            speakerName = try? container.decodeIfPresent(String.self, forKey: .speaker)
            speakerObject = nil
        }
    }
}

/// Tolerant wrapper: non-object entries in a segments array decode as
/// .invalid and are skipped, mirroring Python's isinstance(seg, dict) guard.
public enum MaybeSegment: Decodable, Sendable {
    case segment(RawSegment)
    case invalid

    public init(from decoder: Decoder) throws {
        if let seg = try? RawSegment(from: decoder) {
            self = .segment(seg)
        } else {
            self = .invalid
        }
    }
}

func resolveSpeaker(_ seg: RawSegment) -> String {
    if let sp = seg.speakerObject {
        if sp.attribution == "me" || sp.source == "microphone" { return "Me" }
        if let name = sp.name, !name.isEmpty { return name }
        return "Them"
    }
    if seg.source == "microphone" { return "Me" }
    if let name = seg.speakerName, !name.isEmpty { return name }
    return "Them"
}

private func normName(_ name: String) -> String {
    name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
}

/// Full match, or first-name-only on either side ("Dave" label vs
/// "Dave Suzuki" alias and vice versa) — Granola labels the same person
/// inconsistently. Port of _name_match in granola/source.py.
private func nameMatch(_ speaker: String, _ alias: String) -> Bool {
    if speaker == alias { return true }
    let aliasFirst = alias.split(separator: " ").first.map(String.init) ?? alias
    let speakerFirst = speaker.split(separator: " ").first.map(String.init) ?? speaker
    return speaker == aliasFirst || speakerFirst == alias
}

/// Which speaker label is the user in this meeting — port of
/// resolve_self_speaker in granola/source.py.
///
/// "Me" is whoever captured the note (their microphone), not necessarily the
/// user: shared meetings someone else recorded label THAT person "Me", and
/// the user's own words show up under their display name. If a named speaker
/// matches one of myNames, count that speaker; otherwise fall back to "Me".
public func resolveSelfSpeaker(_ utterances: [Utterance], myNames: [String]) -> String {
    let aliases = myNames.map(normName).filter { !$0.isEmpty }
    guard !aliases.isEmpty else { return "Me" }
    var words: [String: Int] = [:]
    for utterance in utterances {
        if utterance.speaker == "Me" || utterance.speaker == "Them" { continue }
        words[utterance.speaker, default: 0] +=
            utterance.text.split(whereSeparator: { $0.isWhitespace }).count
    }
    let matched = words.keys.filter { speaker in
        aliases.contains { nameMatch(normName(speaker), $0) }
    }
    // Several labels can match (e.g. "Dave" and "Dave Suzuki"): most words
    // wins; name breaks exact ties deterministically (same as Python's max).
    return matched.max { (words[$0]!, $0) < (words[$1]!, $1) } ?? "Me"
}

/// Did the user capture this note? true/false when the note's owner metadata
/// plus the user's configured identity decide it; nil when unknowable.
/// Port of owned_by_me in granola/source.py.
public func ownedByMe(
    ownerEmail: String?, ownerName: String?, myEmail: String?, myNames: [String]
) -> Bool? {
    let ownEmail = ownerEmail?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    let mineEmail = myEmail?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    if !ownEmail.isEmpty, !mineEmail.isEmpty {
        return ownEmail == mineEmail
    }
    if let ownerName, !normName(ownerName).isEmpty {
        let aliases = myNames.map(normName).filter { !$0.isEmpty }
        if !aliases.isEmpty {
            return aliases.contains { nameMatch(normName(ownerName), $0) }
        }
    }
    return nil
}

/// Which speaker to count, or "" for none — port of self_speaker_for in
/// granola/source.py. "" happens when the note is known to be someone ELSE's
/// and no named speaker matches the user: they weren't in the meeting (or
/// never spoke), so counting "Me" would pin the note-taker's fillers on them.
public func selfSpeakerFor(
    _ utterances: [Utterance], myNames: [String], myEmail: String?,
    ownerEmail: String?, ownerName: String?
) -> String {
    let speaker = resolveSelfSpeaker(utterances, myNames: myNames)
    if speaker == "Me",
       ownedByMe(ownerEmail: ownerEmail, ownerName: ownerName,
                 myEmail: myEmail, myNames: myNames) == false {
        return ""
    }
    return speaker
}

/// Merge consecutive same-speaker segments so phrases and stutter-repeats
/// that span a segment boundary are still detectable.
public func mergeSegments(_ segments: [MaybeSegment]) -> [Utterance] {
    var merged: [Utterance] = []
    for maybe in segments {
        guard case let .segment(seg) = maybe else { continue }
        let text = (seg.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let speaker = resolveSpeaker(seg)
        if let last = merged.last, last.speaker == speaker {
            merged[merged.count - 1].text += " " + text
        } else {
            merged.append(Utterance(speaker: speaker, text: text))
        }
    }
    return merged
}
