// Port of merge_segments / _speaker from src/fillerkiller/granola/source.py.
// Handles both Granola transcript shapes: the official API's nested
// speaker: {source, attribution, name} and the legacy flat source field.

import Foundation

public struct RawSegment {
    public let text: String?
    public let source: String?
    public let speakerName: String? // flat string speaker
    public let speakerObject: SpeakerObject?

    public struct SpeakerObject {
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
public enum MaybeSegment: Decodable {
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
