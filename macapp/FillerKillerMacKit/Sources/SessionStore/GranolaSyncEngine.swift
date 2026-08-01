// Incremental Granola sync into the prototype schema — mirrors the Python
// sync_meetings(): a note is re-analyzed only if new or its updated_at
// changed; transcript-null notes (still processing) are retried next sync;
// vocalized fillers are excluded on this path (Granola's ASR strips um/uh,
// counting them would misstate post-hoc rates).

import DetectorKit
import Foundation
import GRDB

public struct GranolaSyncStats: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var skipped = 0
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

    public init(store: SessionStore, client: any GranolaAPI) {
        self.store = store
        self.client = client
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
        return stats
    }

    private func storeMeeting(
        stub: GranolaNoteStub, detail: GranolaNoteDetail, utterances: [Utterance]
    ) throws {
        let result = analyzeUtterances(utterances, speaker: "Me", includeVocalized: false)
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [stub.id])
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, updated_at, word_count,
                    filler_count, per_100_words, synced_at) VALUES (?,?,?,?,?,?,?,?)
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
                ]
            )
            for (idx, utterance) in utterances.enumerated() {
                try db.execute(
                    sql: "INSERT INTO utterances (meeting_id, idx, speaker, text) VALUES (?,?,?,?)",
                    arguments: [stub.id, idx, utterance.speaker, utterance.text]
                )
            }
            for hit in result.hits {
                try db.execute(
                    sql: """
                    INSERT INTO filler_hits (meeting_id, utterance_idx, term, category, start, "end")
                    VALUES (?,?,?,?,?,?)
                    """,
                    arguments: [stub.id, hit.utteranceIdx, hit.term, hit.category, hit.start, hit.end]
                )
            }
        }
    }
}
