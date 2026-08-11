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
        try await store.pool.read { db in
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

    func testSyncNeverStoresRepetitions() async throws {
        let store = try tempStore()
        // "I I" and "the the" would be genuine stutters on the live path;
        // from Granola they're indistinguishable from its doubled-word ASR
        // noise, so the sync layer drops the whole category.
        let transcript = try segments("""
        [{"text": "I I think the the plan works, you know.",
          "speaker": {"source": "microphone", "attribution": "me"}}]
        """)
        let api = StubAPI(
            stubs: [GranolaNoteStub(id: "n1", title: "Planning",
                                    createdAt: "2026-08-01T10:00:00Z",
                                    updatedAt: "2026-08-01T11:00:00Z")],
            details: ["n1": GranolaNoteDetail(id: "n1", title: "Planning",
                                              createdAt: "2026-08-01T10:00:00Z",
                                              updatedAt: "2026-08-01T11:00:00Z",
                                              transcript: transcript)]
        )
        _ = try await GranolaSyncEngine(store: store, client: api).sync()
        let (terms, fillerCount) = try await store.pool.read { db in
            (
                try Row.fetchAll(
                    db, sql: "SELECT term, category FROM filler_hits WHERE meeting_id = 'n1'"
                ).map { ($0["term"] as String, $0["category"] as String) },
                try Int.fetchOne(
                    db, sql: "SELECT filler_count FROM meetings WHERE id = 'n1'"
                ) ?? -1
            )
        }
        XCTAssertEqual(terms.map { $0.0 }, ["you know"])
        XCTAssertFalse(terms.contains { $0.1 == "repetition" })
        XCTAssertEqual(fillerCount, 1, "count must match the stored hits, not the raw analysis")
    }

    func testRemovedMeetingNeverReimports() async throws {
        let store = try tempStore()
        let transcript = try segments("""
        [{"text": "Um so basically we ship it, you know.",
          "speaker": {"source": "microphone", "attribution": "me"}}]
        """)
        let api = StubAPI(
            stubs: [GranolaNoteStub(id: "n1", title: "Pratik's transition",
                                    createdAt: "2026-07-30T10:00:00Z",
                                    updatedAt: "2026-07-30T11:00:00Z")],
            details: ["n1": GranolaNoteDetail(id: "n1", title: "Pratik's transition",
                                              createdAt: "2026-07-30T10:00:00Z",
                                              updatedAt: "2026-07-30T11:00:00Z",
                                              transcript: transcript)]
        )
        let engine = GranolaSyncEngine(store: store, client: api)
        _ = try await engine.sync()
        XCTAssertEqual(try store.meetingCount(), 1)

        try store.removeMeeting(id: "n1", title: "Pratik's transition")
        XCTAssertEqual(try store.meetingCount(), 0)
        let orphans = try await store.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM utterances WHERE meeting_id = 'n1'"
            ) ?? 0
        }
        XCTAssertEqual(orphans, 0, "transcript must cascade with the meeting")

        // The probe must not see the removed note as new (else it would
        // trigger a pointless full sync every few minutes forever).
        let needs = try await engine.needsSync()
        XCTAssertFalse(needs)
        let resync = try await engine.sync()
        XCTAssertEqual(resync.added, 0)
        XCTAssertEqual(resync.skipped, 1)
        XCTAssertEqual(try store.meetingCount(), 0)

        // Undo path: clearing exclusions re-imports on the next sync.
        try store.clearExcludedMeetings()
        let needsAfterClear = try await engine.needsSync()
        XCTAssertTrue(needsAfterClear)
        let restored = try await engine.sync()
        XCTAssertEqual(restored.added, 1)
        XCTAssertEqual(try store.meetingCount(), 1)
    }

    func testSharedNoteCountsNamedSelfSpeakerNotNoteTaker() async throws {
        let store = try tempStore()
        // Someone else captured this note: their mic is "Me", Dave is named.
        let transcript = try segments("""
        [{"text": "Yeah. Like, I think, like, basically it went well. Right?",
          "speaker": {"source": "microphone", "attribution": "me"}},
         {"text": "Sounds good. That is all I wanted to see.",
          "speaker": {"source": "system", "name": "Dave Suzuki"}}]
        """)
        let api = StubAPI(
            stubs: [GranolaNoteStub(id: "s1", title: "Shared", createdAt: "2026-08-03T19:30:00Z",
                                    updatedAt: "v1")],
            details: ["s1": GranolaNoteDetail(id: "s1", title: "Shared", createdAt: nil,
                                              updatedAt: "v1", transcript: transcript)]
        )

        // Synced before any name was configured: note-taker's mic counted.
        _ = try await GranolaSyncEngine(store: store, client: api).sync()
        try await store.pool.read { db in
            let speaker = try String.fetchOne(
                db, sql: "SELECT self_speaker FROM meetings WHERE id = 's1'"
            )
            XCTAssertEqual(speaker, "Me")
            let fillers = try Int.fetchOne(
                db, sql: "SELECT filler_count FROM meetings WHERE id = 's1'"
            )
            XCTAssertGreaterThan(fillers ?? 0, 0)
        }

        // Name configured later: the unchanged (skipped) note is healed from
        // stored utterances — Dave's clean line replaces the note-taker's.
        let healed = try await GranolaSyncEngine(
            store: store, client: api, myNames: ["Dave Suzuki"]
        ).sync()
        XCTAssertEqual(healed, GranolaSyncStats(added: 0, updated: 0, skipped: 1,
                                                reattributed: 1))
        try await store.pool.read { db in
            let speaker = try String.fetchOne(
                db, sql: "SELECT self_speaker FROM meetings WHERE id = 's1'"
            )
            XCTAssertEqual(speaker, "Dave Suzuki")
            let fillers = try Int.fetchOne(
                db, sql: "SELECT filler_count FROM meetings WHERE id = 's1'"
            )
            XCTAssertEqual(fillers, 0)
            let words = try Int.fetchOne(
                db, sql: "SELECT word_count FROM meetings WHERE id = 's1'"
            )
            XCTAssertEqual(words, 9)
            let hitCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM filler_hits")
            XCTAssertEqual(hitCount, 0)
        }

        // Steady state: nothing left to heal.
        let steady = try await GranolaSyncEngine(
            store: store, client: api, myNames: ["Dave Suzuki"]
        ).sync()
        XCTAssertEqual(steady, GranolaSyncStats(added: 0, updated: 0, skipped: 1,
                                                reattributed: 0))
    }

    func testNeedsSyncProbe() async throws {
        let store = try tempStore()
        let transcript = try segments("""
        [{"text": "kind of fine", "speaker": {"source": "microphone", "attribution": "me"}}]
        """)
        let v1 = StubAPI(
            stubs: [GranolaNoteStub(id: "n1", title: "A", createdAt: nil, updatedAt: "v1")],
            details: ["n1": GranolaNoteDetail(id: "n1", title: "A", createdAt: nil,
                                              updatedAt: "v1", transcript: transcript)]
        )
        let engine = GranolaSyncEngine(store: store, client: v1)

        // Empty store: the note is unknown.
        let before = try await engine.needsSync()
        XCTAssertTrue(before)

        // After a sync everything matches.
        _ = try await engine.sync()
        let after = try await engine.needsSync()
        XCTAssertFalse(after)

        // A bumped updated_at is detected.
        let v2 = StubAPI(
            stubs: [GranolaNoteStub(id: "n1", title: "A", createdAt: nil, updatedAt: "v2")],
            details: [:]
        )
        let changed = try await GranolaSyncEngine(store: store, client: v2).needsSync()
        XCTAssertTrue(changed)

        // A brand-new note is detected.
        let v3 = StubAPI(
            stubs: [GranolaNoteStub(id: "n1", title: "A", createdAt: nil, updatedAt: "v1"),
                    GranolaNoteStub(id: "n2", title: "B", createdAt: nil, updatedAt: "v1")],
            details: [:]
        )
        let grown = try await GranolaSyncEngine(store: store, client: v3).needsSync()
        XCTAssertTrue(grown)
    }

    func testForeignNoteWithoutMyVoiceIsNotCounted() async throws {
        let store = try tempStore()
        // Rhonda's note for a meeting Dave didn't attend: her mic is "Me",
        // Dave never appears.
        let transcript = try segments("""
        [{"text": "so so basically you know",
          "speaker": {"source": "microphone", "attribution": "me"}},
         {"text": "right right", "speaker": {"source": "system"}}]
        """)
        let owner = GranolaOwner(email: "rhonda.simmons@hiya.com", name: "Rhonda Simmons")
        let api = StubAPI(
            stubs: [GranolaNoteStub(id: "f1", title: "Revision de datos",
                                    createdAt: "2026-08-01T10:00:00Z", updatedAt: "v1",
                                    owner: owner)],
            details: ["f1": GranolaNoteDetail(id: "f1", title: "Revision de datos",
                                              createdAt: nil, updatedAt: "v1",
                                              transcript: transcript, owner: owner)]
        )
        _ = try await GranolaSyncEngine(
            store: store, client: api,
            myNames: ["Dave Suzuki"], myEmail: "dave.suzuki@hiya.com"
        ).sync()
        try await store.pool.read { db in
            let speaker = try String.fetchOne(
                db, sql: "SELECT self_speaker FROM meetings WHERE id = 'f1'"
            )
            XCTAssertEqual(speaker, "")
            let words = try Int.fetchOne(
                db, sql: "SELECT word_count FROM meetings WHERE id = 'f1'"
            )
            XCTAssertEqual(words, 0)
            let hits = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM filler_hits")
            XCTAssertEqual(hits, 0)
            let utterances = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM utterances WHERE meeting_id = 'f1'"
            )
            XCTAssertEqual(utterances, 2, "transcript stays browsable")
        }
    }

    func testOwnerBackfillHealsRowsSyncedBeforeOwnerColumns() async throws {
        let store = try tempStore()
        let transcript = try segments("""
        [{"text": "so so basically you know",
          "speaker": {"source": "microphone", "attribution": "me"}}]
        """)
        // First sync: API gave no owner metadata — counted as Me (the bug).
        let anonymous = StubAPI(
            stubs: [GranolaNoteStub(id: "f1", title: "Foreign", createdAt: nil,
                                    updatedAt: "v1")],
            details: ["f1": GranolaNoteDetail(id: "f1", title: "Foreign", createdAt: nil,
                                              updatedAt: "v1", transcript: transcript)]
        )
        _ = try await GranolaSyncEngine(
            store: store, client: anonymous,
            myNames: ["Dave Suzuki"], myEmail: "dave.suzuki@hiya.com"
        ).sync()
        try await store.pool.read { db in
            let fillers = try Int.fetchOne(
                db, sql: "SELECT filler_count FROM meetings WHERE id = 'f1'"
            )
            XCTAssertGreaterThan(fillers ?? 0, 0)
        }

        // Later sync: unchanged note, but the list now carries the owner —
        // backfilled on the skip path, then healed to not-counted.
        let withOwner = StubAPI(
            stubs: [GranolaNoteStub(id: "f1", title: "Foreign", createdAt: nil,
                                    updatedAt: "v1",
                                    owner: GranolaOwner(email: "rhonda.simmons@hiya.com",
                                                        name: nil))],
            details: [:]
        )
        let stats = try await GranolaSyncEngine(
            store: store, client: withOwner,
            myNames: ["Dave Suzuki"], myEmail: "dave.suzuki@hiya.com"
        ).sync()
        XCTAssertEqual(stats, GranolaSyncStats(added: 0, updated: 0, skipped: 1,
                                               reattributed: 1))
        try await store.pool.read { db in
            let speaker = try String.fetchOne(
                db, sql: "SELECT self_speaker FROM meetings WHERE id = 'f1'"
            )
            XCTAssertEqual(speaker, "")
            let words = try Int.fetchOne(
                db, sql: "SELECT word_count FROM meetings WHERE id = 'f1'"
            )
            XCTAssertEqual(words, 0)
        }
    }

    func testOwnerDecodingShapes() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let objectShape = try decoder.decode(GranolaNoteStub.self, from: Data("""
        {"id": "n1", "owner": {"email": "P@Hiya.com", "name": "Prateek Saxena"}}
        """.utf8))
        XCTAssertEqual(objectShape.ownerEmail, "p@hiya.com")
        XCTAssertEqual(objectShape.ownerName, "Prateek Saxena")

        let stringShape = try decoder.decode(GranolaNoteStub.self, from: Data("""
        {"id": "n2", "created_by": "rhonda.simmons@hiya.com"}
        """.utf8))
        XCTAssertEqual(stringShape.ownerEmail, "rhonda.simmons@hiya.com")
        XCTAssertNil(stringShape.ownerName)

        let noOwner = try decoder.decode(GranolaNoteStub.self, from: Data("""
        {"id": "n3", "title": "plain"}
        """.utf8))
        XCTAssertNil(noOwner.ownerEmail)
        XCTAssertNil(noOwner.ownerName)

        let weirdShape = try decoder.decode(GranolaNoteStub.self, from: Data("""
        {"id": "n4", "owner": 42}
        """.utf8))
        XCTAssertNil(weirdShape.ownerEmail)
        XCTAssertNil(weirdShape.ownerName)
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
        try await store.pool.read { db in
            let title = try String.fetchOne(
                db, sql: "SELECT title FROM meetings WHERE id = 'n1'"
            )
            XCTAssertEqual(title, "A (edited)")
        }
    }
}
