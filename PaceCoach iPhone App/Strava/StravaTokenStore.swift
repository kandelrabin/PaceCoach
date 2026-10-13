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
    private let provisioningCounterAccount = "provisioningCounter"

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

    /// Monotonic across app launches; the clock seed also covers a fresh iPhone install.
    /// This metadata is stored beside the OAuth record, never in the transfer payload alone.
    func nextProvisioningSequence() throws -> Int64 {
        var query = baseQuery
        query[kSecAttrAccount as String] = provisioningCounterAccount
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let previous: Int64
        if status == errSecItemNotFound {
            previous = 0
        } else if status == errSecSuccess, let data = result as? Data,
                  let value = Int64(String(decoding: data, as: UTF8.self)) {
            previous = value
        } else {
            throw StravaTokenStoreError.keychain
        }

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard previous < Int64.max else { throw StravaTokenStoreError.keychain }
        let next = max(now, previous + 1)
        let data = Data(String(next).utf8)
        let key = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provisioningCounterAccount
        ] as [String: Any]
        if status == errSecItemNotFound {
            var add = key
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw StravaTokenStoreError.keychain
            }
        } else {
            guard SecItemUpdate(key as CFDictionary,
                                [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
                throw StravaTokenStoreError.keychain
            }
        }
        return next
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
