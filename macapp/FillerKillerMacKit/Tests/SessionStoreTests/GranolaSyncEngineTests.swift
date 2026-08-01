// Mirrors the Python sync tests: add/update/skip accounting, transcript-null
// retry, Me-only analysis with vocalized excluded.

import DetectorKit
import GRDB
import XCTest
@testable import SessionStore

private struct StubAPI: GranolaAPI {
    let stubs: [GranolaNoteStub]
    let details: [String: GranolaNoteDetail]

    func listNotes() async throws -> [GranolaNoteStub] { stubs }

    func noteDetail(id: String) async throws -> GranolaNoteDetail {
        guard let detail = details[id] else {
            throw GranolaError(message: "unexpected detail fetch: \(id)")
        }
        return detail
    }
}

private func segments(_ json: String) throws -> [MaybeSegment] {
    try JSONDecoder().decode([MaybeSegment].self, from: Data(json.utf8))
}

final class GranolaSyncEngineTests: XCTestCase {
    private func tempStore() throws -> SessionStore {
        try SessionStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("fk.db"))
    }

    func testSyncAddsSkipsAndRetriesProcessing() async throws {
        let store = try tempStore()
        let transcript = try segments("""
        [{"text": "Um so basically we ship it, you know.",
          "speaker": {"source": "microphone", "attribution": "me"}},
         {"text": "Agreed.", "speaker": {"source": "system"}}]
        """)
        let api = StubAPI(
            stubs: [
                GranolaNoteStub(id: "n1", title: "Sync", createdAt: "2026-07-30T10:00:00Z",
                                updatedAt: "2026-07-30T11:00:00Z"),
                GranolaNoteStub(id: "n2", title: "Processing", createdAt: "2026-07-31T10:00:00Z",
                                updatedAt: nil),
            ],
            details: [
                "n1": GranolaNoteDetail(id: "n1", title: "Sync", createdAt: "2026-07-30T10:00:00Z",
                                        updatedAt: "2026-07-30T11:00:00Z", transcript: transcript),
                "n2": GranolaNoteDetail(id: "n2", title: "Processing", createdAt: nil,
                                        updatedAt: nil, transcript: nil),
            ]
        )
        let engine = GranolaSyncEngine(store: store, client: api)

        let first = try await engine.sync()
        XCTAssertEqual(first, GranolaSyncStats(added: 1, updated: 0, skipped: 0))
        XCTAssertEqual(try store.meetingCount(), 1)

        // Second sync: n1 unchanged (skipped, no re-store), n2 still processing.
        let second = try await engine.sync()
        XCTAssertEqual(second, GranolaSyncStats(added: 0, updated: 0, skipped: 1))

        // Vocalized excluded post-hoc; "so" transparency keeps it counted;
        // system speaker not analyzed.
        try store.pool.read { db in
            let terms = try String.fetchAll(
                db, sql: "SELECT term FROM filler_hits WHERE meeting_id = 'n1' ORDER BY term"
            )
            XCTAssertEqual(terms, ["basically", "so", "you know"])
            let speakers = try String.fetchAll(
                db, sql: "SELECT speaker FROM utterances WHERE meeting_id = 'n1' ORDER BY idx"
            )
            XCTAssertEqual(speakers, ["Me", "Them"])
        }
    }

    func testChangedNoteReanalyzedWithoutDuplicates() async throws {
        let store = try tempStore()
        let transcript = try segments("""
        [{"text": "kind of fine", "speaker": {"source": "microphone", "attribution": "me"}}]
        """)
        let v1 = StubAPI(
            stubs: [GranolaNoteStub(id: "n1", title: "A", createdAt: "2026-07-30T10:00:00Z",
                                    updatedAt: "v1")],
            details: ["n1": GranolaNoteDetail(id: "n1", title: "A", createdAt: nil,
                                              updatedAt: "v1", transcript: transcript)]
        )
        _ = try await GranolaSyncEngine(store: store, client: v1).sync()

        let v2 = StubAPI(
            stubs: [GranolaNoteStub(id: "n1", title: "A", createdAt: "2026-07-30T10:00:00Z",
                                    updatedAt: "v2")],
            details: ["n1": GranolaNoteDetail(id: "n1", title: "A (edited)", createdAt: nil,
                                              updatedAt: "v2", transcript: transcript)]
        )
        let stats = try await GranolaSyncEngine(store: store, client: v2).sync()
        XCTAssertEqual(stats, GranolaSyncStats(added: 0, updated: 1, skipped: 0))
        XCTAssertEqual(try store.meetingCount(), 1)
        try store.pool.read { db in
            let title = try String.fetchOne(
                db, sql: "SELECT title FROM meetings WHERE id = 'n1'"
            )
            XCTAssertEqual(title, "A (edited)")
        }
    }
}
