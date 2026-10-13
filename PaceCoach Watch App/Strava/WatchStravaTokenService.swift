import Foundation

enum WatchStravaTokenError: Error {
    case notProvisioned
    case invalidResponse
    case httpStatus(Int)
}

struct WatchStravaAccessToken {
    let value: String
    let refreshed: Bool
    let refreshTokenChanged: Bool
}

/// The Watch is the sole refresher after provisioning. All callers share one
/// in-flight request, including a development force-refresh request.
@MainActor
final class WatchStravaTokenService {
    static let shared = WatchStravaTokenService()

    private static let safetyWindowSeconds = 300
    private let store = WatchStravaCredentialStore()
    private var refreshTask: Task<WatchStravaAccessToken, Error>?

    func validAccessToken(forceRefresh: Bool = false) async throws -> WatchStravaAccessToken {
        if let refreshTask {
            let result = try await refreshTask.value
            return try currentToken(after: result)
        }
        guard let record = try store.loadRecord() else {
            throw WatchStravaTokenError.notProvisioned
        }
        let now = Int(Date().timeIntervalSince1970)
        if !forceRefresh && record.payload.expiresAt > now + Self.safetyWindowSeconds {
            return WatchStravaAccessToken(value: record.payload.accessToken,
                                          refreshed: false, refreshTokenChanged: false)
        }

        let task = Task { try await Self.refresh(record: record, store: store) }
        refreshTask = task
        defer { refreshTask = nil }
        let result = try await task.value
        return try currentToken(after: result)
    }

    private func currentToken(after result: WatchStravaAccessToken) throws -> WatchStravaAccessToken {
        guard let latest = try store.load(),
              latest.expiresAt > Int(Date().timeIntervalSince1970) else {
            throw WatchStravaTokenError.notProvisioned
        }
        return WatchStravaAccessToken(value: latest.accessToken,
                                      refreshed: result.refreshed,
                                      refreshTokenChanged: result.refreshTokenChanged)
    }

    /// Incoming provisioning waits for a refresh so it cannot replace a newly
    /// rotated token between the network response and the Keychain write.
    func acceptProvisioning(_ payload: StravaProvisioningPayload) async throws {
        if let refreshTask { _ = try? await refreshTask.value }
        try store.accept(payload)
    }

    private static func refresh(
        record: WatchStravaCredentialRecord,
        store: WatchStravaCredentialStore
    ) async throws -> WatchStravaAccessToken {
        let current = record.payload
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: current.clientID),
            URLQueryItem(name: "client_secret", value: current.clientSecret),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: current.refreshToken)
        ]
        guard let data = body.percentEncodedQuery?.data(using: .utf8) else {
            throw WatchStravaTokenError.invalidResponse
        }
        request.httpBody = data

        let session = URLSession(configuration: .ephemeral)
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WatchStravaTokenError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw WatchStravaTokenError.httpStatus(http.statusCode)
        }
        let tokens = try JSONDecoder().decode(RefreshResponse.self, from: responseData)
        guard !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
              tokens.expiresAt > Int(Date().timeIntervalSince1970) else {
            throw WatchStravaTokenError.invalidResponse
        }

        // Strava's refresh response has no scope; retain the original grant.
        // A single Keychain update commits the new access and refresh tokens.
        let saved = try store.saveRefresh(
            basedOn: record,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt
        )
        CompanionConnectivity.shared.reportWatchRefreshOwnership(
            identifier: saved.identifier, sequence: saved.sequence
        )
        return WatchStravaAccessToken(value: saved.accessToken, refreshed: true,
                                      refreshTokenChanged: saved.refreshToken != current.refreshToken)
    }
}

private struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}
