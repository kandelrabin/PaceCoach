import CryptoKit
import Foundation
import Security

enum WatchStravaStoreError: Error {
    case invalidPayload
    case stalePayload
    case staleCredential
    case changedDuringRefresh
    case keychain
}

/// The existing Stage 3 Keychain item may contain a bare payload. Read it as a
/// legacy record, then migrate on the next successful write.
struct WatchStravaCredentialRecord: Codable, Equatable {
    let payload: StravaProvisioningPayload
    let watchOwnsRefreshToken: Bool
    let provisionedRefreshTokenDigest: Data?
}

struct WatchStravaCredentialStore {
    private let service = "com.rabinkandel.PaceCoach.strava"
    private let account = "watchProvisioning"

    func load() throws -> StravaProvisioningPayload? {
        try loadRecord()?.payload
    }

    func loadRecord() throws -> WatchStravaCredentialRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WatchStravaStoreError.keychain
        }
        if let record = try? JSONDecoder().decode(WatchStravaCredentialRecord.self, from: data),
           record.payload.isValid,
           !record.watchOwnsRefreshToken || record.provisionedRefreshTokenDigest != nil {
            return record
        }
        if let payload = try? JSONDecoder().decode(StravaProvisioningPayload.self, from: data),
           payload.isValid {
            return WatchStravaCredentialRecord(payload: payload,
                                               watchOwnsRefreshToken: false,
                                               provisionedRefreshTokenDigest: nil)
        }
        throw WatchStravaStoreError.keychain
    }

    /// One Keychain item holds both the credentials and their ordering metadata.
    /// Updating it atomically prevents a failed write from advancing the version.
    func accept(_ payload: StravaProvisioningPayload) throws {
        guard payload.isValid else { throw WatchStravaStoreError.invalidPayload }
        if let current = try loadRecord() {
            if current.watchOwnsRefreshToken,
               current.provisionedRefreshTokenDigest == Self.digest(payload.refreshToken) {
                throw WatchStravaStoreError.staleCredential
            }
            if current.payload.sequence == payload.sequence &&
               current.payload.identifier == payload.identifier {
                guard !current.watchOwnsRefreshToken && current.payload == payload else {
                    throw WatchStravaStoreError.stalePayload
                }
                return // Exact repeat delivery of an already persisted transfer.
            }
            guard payload.sequence > current.payload.sequence else {
                throw WatchStravaStoreError.stalePayload
            }
        }

        try save(WatchStravaCredentialRecord(payload: payload,
                                             watchOwnsRefreshToken: false,
                                             provisionedRefreshTokenDigest: nil))
    }

    /// Replaces credentials, scope, and ownership metadata in a single Keychain item.
    func saveRefresh(
        basedOn previous: WatchStravaCredentialRecord,
        accessToken: String,
        refreshToken: String,
        expiresAt: Int
    ) throws -> StravaProvisioningPayload {
        guard let current = try loadRecord(), current == previous else {
            throw WatchStravaStoreError.changedDuringRefresh
        }
        let old = current.payload
        let updated = StravaProvisioningPayload(
            protocolVersion: old.protocolVersion,
            identifier: old.identifier,
            sequence: old.sequence,
            clientID: old.clientID,
            clientSecret: old.clientSecret,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scope: old.scope
        )
        guard updated.isValid else { throw WatchStravaStoreError.invalidPayload }
        try save(WatchStravaCredentialRecord(
            payload: updated,
            watchOwnsRefreshToken: true,
            provisionedRefreshTokenDigest: current.provisionedRefreshTokenDigest
                ?? Self.digest(old.refreshToken)
        ))
        return updated
    }

    private func save(_ record: WatchStravaCredentialRecord) throws {
        let data = try JSONEncoder().encode(record)
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

    private static func digest(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
