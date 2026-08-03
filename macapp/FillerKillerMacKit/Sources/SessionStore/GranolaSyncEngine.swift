// Incremental Granola sync into the prototype schema — mirrors the Python
// sync_meetings(): a note is re-analyzed only if new or its updated_at
// changed; transcript-null notes (still processing) are retried next sync;
// vocalized fillers are excluded on this path (Granola's ASR strips um/uh,
// counting them would misstate post-hoc rates).
//
// Speaker attribution: "Me" in a Granola transcript is whoever captured the
// note. For shared meetings someone else recorded, the user's own words are
// under their display name — resolveSelfSpeaker picks the right label per
// meeting, and already-synced meetings are healed from stored utterances
// whenever the resolution changes (e.g. myNames configured after the fact).

import DetectorKit
import Foundation
import GRDB

public struct GranolaSyncStats: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var skipped = 0
    public var reattributed = 0

    public init(added: Int = 0, updated: Int = 0, skipped: Int = 0, reattributed: Int = 0) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
        self.reattributed = reattributed
    }
}

/// Seam for tests: GranolaClient conforms; stubs can too.
public protocol GranolaAPI: Sendable {
    func listNotes() async throws -> [GranolaNoteStub]
    func noteDetail(id: String) async throws -> GranolaNoteDetail
}

extension GranolaClient: GranolaAPI {}

public final class GranolaSyncEngine {
    private let store: SessionStore
    private let client: any GranolaAPI
    private let myNames: [String]

    public init(store: SessionStore, client: any GranolaAPI, myNames: [String] = []) {
        self.store = store
        self.client = client
        self.myNames = myNames
    }

    public func sync() async throws -> GranolaSyncStats {
        let known: [String: String?] = try await store.pool.read { db in
            var map: [String: String?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, updated_at FROM meetings") {
                map[row["id"] as String] = row["updated_at"] as String?
            }
            return map
        }

        var stats = GranolaSyncStats()
        for stub in try await client.listNotes() {
            if let existing = known[stub.id], existing == stub.updatedAt {
                stats.skipped += 1
                continue
            }
            let detail = try await client.noteDetail(id: stub.id)
            guard let segments = detail.transcript, !segments.isEmpty else {
                continue // still processing; picked up next sync
            }
            let utterances = mergeSegments(segments)
            guard !utterances.isEmpty else { continue }
            if known[stub.id] != nil {
                stats.updated += 1
            } else {
                stats.added += 1
            }
            try storeMeeting(stub: stub, detail: detail, utterances: utterances)
        }
        stats.reattributed = try reattributeStored()
        return stats
    }

    private func storeMeeting(
        stub: GranolaNoteStub, detail: GranolaNoteDetail, utterances: [Utterance]
    ) throws {
        let speaker = resolveSelfSpeaker(utterances, myNames: myNames)
        let result = analyzeUtterances(utterances, speaker: speaker, includeVocalized: false)
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [stub.id])
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, updated_at, word_count,
                    filler_count, per_100_words, synced_at, self_speaker)
                VALUES (?,?,?,?,?,?,?,?,?)
                """,
                arguments: [
                    stub.id,
                    detail.title ?? stub.title ?? "(untitled)",
                    detail.createdAt ?? stub.createdAt ?? "",
                    stub.updatedAt,
                    result.wordCount,
                    result.fillerCount,
                    result.per100Words,
                    now,
                    speaker,
                ]
            )
            for (idx, utterance) in utterances.enumerated() {
                try db.execute(
                    sql: "INSERT INTO utterances (meeting_id, idx, speaker, text) VALUES (?,?,?,?)",
                    arguments: [stub.id, idx, utterance.speaker, utterance.text]
                )
            }
            try Self.insertHits(db, meetingId: stub.id, hits: result.hits)
        }
    }

    /// Re-run speaker attribution over already-synced meetings using their
    /// stored utterances — a new or changed myNames heals history without
    /// refetching a single transcript. Returns how many meetings changed.
    private func reattributeStored() throws -> Int {
        let myNames = self.myNames
        return try store.pool.write { db -> Int in
            var healed = 0
            let meetings = try Row.fetchAll(db, sql: "SELECT id, self_speaker FROM meetings")
            for row in meetings {
                let meetingId: String = row["id"]
                let stored: String = row["self_speaker"]
                let utterances = try Row.fetchAll(
                    db,
                    sql: "SELECT speaker, text FROM utterances WHERE meeting_id = ? ORDER BY idx",
                    arguments: [meetingId]
                ).map { Utterance(speaker: $0["speaker"], text: $0["text"]) }
                guard !utterances.isEmpty else { continue }
                let speaker = resolveSelfSpeaker(utterances, myNames: myNames)
                guard speaker != stored else { continue }
                let result = analyzeUtterances(
                    utterances, speaker: speaker, includeVocalized: false
                )
                try db.execute(
                    sql: """
                    UPDATE meetings SET word_count = ?, filler_count = ?,
                        per_100_words = ?, self_speaker = ? WHERE id = ?
                    """,
                    arguments: [
                        result.wordCount, result.fillerCount, result.per100Words,
                        speaker, meetingId,
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM filler_hits WHERE meeting_id = ?", arguments: [meetingId]
                )
                try Self.insertHits(db, meetingId: meetingId, hits: result.hits)
                healed += 1
            }
            return healed
        }
    }

    private static func insertHits(
        _ db: Database, meetingId: String, hits: [FillerHit]
    ) throws {
        for hit in hits {
            try db.execute(
                sql: """
                INSERT INTO filler_hits (meeting_id, utterance_idx, term, category, start, "end")
                VALUES (?,?,?,?,?,?)
                """,
                arguments: [meetingId, hit.utteranceIdx, hit.term, hit.category, hit.start, hit.end]
            )
        }
    }
}
