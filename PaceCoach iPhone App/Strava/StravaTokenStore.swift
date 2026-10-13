import Foundation
import Security

struct StravaTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
    }

    var grantsActivityWrite: Bool {
        scope.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .contains("activity:write")
    }
}

enum StravaTokenStoreError: Error {
    case keychain
}

struct StravaTokenStore {
    private let service = "com.rabinkandel.PaceCoach.strava"
    private let account = "oauthTokens"

    func load() throws -> StravaTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StravaTokenStoreError.keychain
        }
        return try JSONDecoder().decode(StravaTokens.self, from: data)
    }

    func save(_ tokens: StravaTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StravaTokenStoreError.keychain }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw StravaTokenStoreError.keychain
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
