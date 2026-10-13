import Foundation
import Security

enum WatchStravaStoreError: Error {
    case invalidPayload
    case stalePayload
    case keychain
}

struct WatchStravaCredentialStore {
    private let service = "com.rabinkandel.PaceCoach.strava"
    private let account = "watchProvisioning"

    func load() throws -> StravaProvisioningPayload? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let payload = try? JSONDecoder().decode(StravaProvisioningPayload.self, from: data),
              payload.isValid else {
            throw WatchStravaStoreError.keychain
        }
        return payload
    }

    /// One Keychain item holds both the credentials and their ordering metadata.
    /// Updating it atomically prevents a failed write from advancing the version.
    func accept(_ payload: StravaProvisioningPayload) throws {
        guard payload.isValid else { throw WatchStravaStoreError.invalidPayload }
        if let current = try load() {
            if current.sequence == payload.sequence && current.identifier == payload.identifier {
                guard current == payload else { throw WatchStravaStoreError.stalePayload }
                return // Exact repeat delivery of an already persisted transfer.
            }
            guard payload.sequence > current.sequence else {
                throw WatchStravaStoreError.stalePayload
            }
        }

        let data = try JSONEncoder().encode(payload)
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw WatchStravaStoreError.keychain }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw WatchStravaStoreError.keychain
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
