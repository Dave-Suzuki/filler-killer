// Official Granola API client — the exact live-verified shape from the
// Python prototype (src/fillerkiller/granola/public_api_source.py):
//   GET /v1/notes?limit=N[&cursor=]  -> {notes, cursor, hasMore}
//   GET /v1/notes/{id}?include=transcript -> detail; transcript null while a
//   meeting is still processing; segments nest speaker {source, attribution}.
// Auth: grn_ API key (Keychain). Read-only.

import DetectorKit
import Foundation
import Security

public struct GranolaError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Tolerant owner payload: an object ({email, name/full_name/display_name})
/// or a bare string (email or name). Never fails decoding the parent note —
/// the exact key/shape has varied across API docs, so parse defensively.
public struct GranolaOwner: Decodable, Sendable {
    public let email: String?
    public let name: String?

    public init(email: String?, name: String?) {
        self.email = email
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case email, name, fullName, displayName
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            func field(_ key: CodingKeys) -> String? {
                (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
            }
            email = field(.email)
            name = field(.name) ?? field(.fullName) ?? field(.displayName)
        } else if let raw = try? decoder.singleValueContainer().decode(String.self),
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            email = trimmed.contains("@") ? trimmed : nil
            name = trimmed.contains("@") ? nil : trimmed
        } else {
            email = nil
            name = nil
        }
    }
}

/// Owner lookup shared by note stubs and details: first candidate key with
/// content wins (mirrors extract_owner in granola/source.py).
func resolveOwner(_ candidates: [GranolaOwner?]) -> (email: String?, name: String?) {
    var email: String?
    var name: String?
    for candidate in candidates {
        if email == nil, let e = candidate?.email,
           !e.trimmingCharacters(in: .whitespaces).isEmpty {
            email = e.trimmingCharacters(in: .whitespaces).lowercased()
        }
        if name == nil, let n = candidate?.name,
           !n.trimmingCharacters(in: .whitespaces).isEmpty {
            name = n.trimmingCharacters(in: .whitespaces)
        }
    }
    return (email, name)
}

public struct GranolaNoteStub: Decodable, Sendable {
    public let id: String
    public let title: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let owner: GranolaOwner?
    public let creator: GranolaOwner?
    public let createdBy: GranolaOwner?
    public let user: GranolaOwner?
    public let author: GranolaOwner?

    public init(
        id: String, title: String?, createdAt: String?, updatedAt: String?,
        owner: GranolaOwner? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.owner = owner
        creator = nil
        createdBy = nil
        user = nil
        author = nil
    }

    public var ownerEmail: String? { resolveOwner([owner, creator, createdBy, user, author]).email }
    public var ownerName: String? { resolveOwner([owner, creator, createdBy, user, author]).name }
}

struct GranolaNotesPage: Decodable {
    let notes: [GranolaNoteStub]
    let cursor: String?
    let hasMore: Bool?
}

public struct GranolaNoteDetail: Decodable, Sendable {
    public let id: String?
    public let title: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let transcript: [MaybeSegment]?
    public let owner: GranolaOwner?
    public let creator: GranolaOwner?
    public let createdBy: GranolaOwner?
    public let user: GranolaOwner?
    public let author: GranolaOwner?

    public init(
        id: String?, title: String?, createdAt: String?, updatedAt: String?,
        transcript: [MaybeSegment]?, owner: GranolaOwner? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcript = transcript
        self.owner = owner
        creator = nil
        createdBy = nil
        user = nil
        author = nil
    }

    public var ownerEmail: String? { resolveOwner([owner, creator, createdBy, user, author]).email }
    public var ownerName: String? { resolveOwner([owner, creator, createdBy, user, author]).name }
}

public struct GranolaClient: Sendable {
    let apiKey: String
    let base: URL
    let pageSize: Int
    private static let maxPages = 20

    public init(
        apiKey: String,
        base: URL = URL(string: "https://public-api.granola.ai/v1")!,
        pageSize: Int = 100
    ) {
        self.apiKey = apiKey
        self.base = base
        self.pageSize = pageSize
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200 ..< 300:
            break
        case 401, 403:
            throw GranolaError(message:
                "Granola rejected the API key. Check the key, and that API access "
                + "is enabled for your workspace/account.")
        case let code:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw GranolaError(message: "Granola API \(path) failed: HTTP \(code) \(body)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Cheap auth/connectivity check; returns visible note count on page one.
    public func ping() async throws -> Int {
        let page: GranolaNotesPage = try await get(
            "notes", query: [URLQueryItem(name: "limit", value: "1")]
        )
        return page.notes.count
    }

    public func listNotes() async throws -> [GranolaNoteStub] {
        var notes: [GranolaNoteStub] = []
        var cursor: String?
        for _ in 0 ..< Self.maxPages {
            var query = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let page: GranolaNotesPage = try await get("notes", query: query)
            notes.append(contentsOf: page.notes)
            guard page.hasMore == true,
                  let next = page.cursor, !next.isEmpty, next != cursor,
                  !page.notes.isEmpty
            else { break }
            cursor = next
        }
        return notes
    }

    public func noteDetail(id: String) async throws -> GranolaNoteDetail {
        try await get(
            "notes/\(id)", query: [URLQueryItem(name: "include", value: "transcript")]
        )
    }
}

/// grn_ API key storage — Keychain, never UserDefaults.
public enum GranolaKeychain {
    private static let service = "com.davesuzuki.FillerKiller"
    private static let account = "granola-api-key"

    public static func save(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
