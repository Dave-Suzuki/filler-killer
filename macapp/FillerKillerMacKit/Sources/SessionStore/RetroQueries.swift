// Read queries for the native retrospective window: a unified meetings +
// live-sessions view (merge is presentation-only; storage stays two tables,
// exactly like the Python dashboard).

import DetectorKit
import Foundation
import GRDB

public struct RetroItem: Identifiable, Sendable, Equatable {
    public enum Source: String, Sendable {
        case meeting, live
    }

    public let id: String // "m:<meeting id>" or "l:<session id>"
    public let source: Source
    public let sourceId: String
    public let title: String
    public let startedAt: String
    public let words: Int
    public let fillers: Int
    public let rate: Double
    /// Which transcript speaker was counted — "Me" unless someone else
    /// captured the note and the user matched a named speaker instead.
    public let selfSpeaker: String

    public var day: String { String(startedAt.prefix(10)) }
}

public struct TermCount: Identifiable, Sendable, Equatable {
    public let term: String
    public let count: Int

    public var id: String { term }
}

public struct TranscriptLine: Identifiable, Sendable {
    public let id: Int
    public let speaker: String // "Me", a name, or a timestamp for live lines
    public let text: String
    public let hits: [FillerHit]
}

extension SessionStore {
    public func retroItems(since cutoff: String?) throws -> [RetroItem] {
        try pool.read { db in
            let since = cutoff ?? ""
            var items: [RetroItem] = []
            let meetings = try Row.fetchAll(
                db,
                sql: """
                SELECT id, title, started_at, word_count, filler_count, per_100_words,
                    self_speaker
                FROM meetings WHERE word_count > 0 AND started_at >= ?
                """,
                arguments: [since]
            )
            for row in meetings {
                let id: String = row["id"]
                items.append(RetroItem(
                    id: "m:\(id)", source: .meeting, sourceId: id,
                    title: row["title"], startedAt: row["started_at"],
                    words: row["word_count"], fillers: row["filler_count"],
                    rate: row["per_100_words"], selfSpeaker: row["self_speaker"]
                ))
            }
            let sessions = try Row.fetchAll(
                db,
                sql: """
                SELECT id, label, started_at, word_count, filler_count, per_100_words
                FROM live_sessions
                WHERE ended_at IS NOT NULL AND word_count > 0 AND started_at >= ?
                """,
                arguments: [since]
            )
            for row in sessions {
                let id: Int64 = row["id"]
                let label: String? = row["label"]
                items.append(RetroItem(
                    id: "l:\(id)", source: .live, sourceId: String(id),
                    title: label ?? "Live session \(id)",
                    startedAt: row["started_at"],
                    words: row["word_count"], fillers: row["filler_count"],
                    rate: row["per_100_words"], selfSpeaker: "Me"
                ))
            }
            return items.sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func topTerms(since cutoff: String?, limit: Int = 8) throws -> [TermCount] {
        try pool.read { db in
            let since = cutoff ?? ""
            var counts: [String: Int] = [:]
            let meetingRows = try Row.fetchAll(
                db,
                sql: """
                SELECT h.term AS term, COUNT(*) AS n FROM filler_hits h
                JOIN meetings m ON m.id = h.meeting_id
                WHERE m.started_at >= ? GROUP BY h.term
                """,
                arguments: [since]
            )
            for row in meetingRows {
                counts[row["term"] as String, default: 0] += row["n"] as Int
            }
            let liveRows = try Row.fetchAll(
                db,
                sql: """
                SELECT h.term AS term, COUNT(*) AS n FROM live_hits h
                JOIN live_sessions s ON s.id = h.session_id
                WHERE s.ended_at IS NOT NULL AND s.started_at >= ? GROUP BY h.term
                """,
                arguments: [since]
            )
            for row in liveRows {
                counts[row["term"] as String, default: 0] += row["n"] as Int
            }
            return counts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit)
                .map { TermCount(term: $0.key, count: $0.value) }
        }
    }

    public func meetingTranscript(meetingId: String) throws -> [TranscriptLine] {
        try pool.read { db in
            let utterances = try Row.fetchAll(
                db,
                sql: "SELECT idx, speaker, text FROM utterances WHERE meeting_id = ? ORDER BY idx",
                arguments: [meetingId]
            )
            let hitRows = try Row.fetchAll(
                db,
                sql: """
                SELECT utterance_idx, term, category, start, "end" FROM filler_hits
                WHERE meeting_id = ?
                """,
                arguments: [meetingId]
            )
            var hitsByIdx: [Int: [FillerHit]] = [:]
            for row in hitRows {
                let idx: Int = row["utterance_idx"]
                hitsByIdx[idx, default: []].append(FillerHit(
                    term: row["term"], category: row["category"],
                    start: row["start"], end: row["end"], utteranceIdx: idx
                ))
            }
            return utterances.map { row in
                let idx: Int = row["idx"]
                return TranscriptLine(
                    id: idx, speaker: row["speaker"], text: row["text"],
                    hits: hitsByIdx[idx] ?? []
                )
            }
        }
    }

    public func liveTranscript(sessionId: Int64) throws -> [TranscriptLine] {
        try pool.read { db in
            let segments = try Row.fetchAll(
                db,
                sql: "SELECT idx, at, text FROM live_segments WHERE session_id = ? ORDER BY idx",
                arguments: [sessionId]
            )
            let hitRows = try Row.fetchAll(
                db,
                sql: """
                SELECT segment_idx, term, category, start, "end" FROM live_hits
                WHERE session_id = ?
                """,
                arguments: [sessionId]
            )
            var hitsByIdx: [Int: [FillerHit]] = [:]
            for row in hitRows {
                let idx: Int = row["segment_idx"]
                hitsByIdx[idx, default: []].append(FillerHit(
                    term: row["term"], category: row["category"],
                    start: row["start"], end: row["end"], utteranceIdx: idx
                ))
            }
            return segments.map { row in
                let idx: Int = row["idx"]
                let at: String = row["at"]
                let clock = at.count >= 19 ? String(at.dropFirst(11).prefix(8)) : at
                return TranscriptLine(
                    id: idx, speaker: clock, text: row["text"],
                    hits: hitsByIdx[idx] ?? []
                )
            }
        }
    }
}
