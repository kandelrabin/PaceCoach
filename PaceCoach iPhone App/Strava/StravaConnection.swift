import AuthenticationServices
import Combine
import Foundation
import Security
import UIKit

@MainActor
final class StravaConnection: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String?

    private static let callbackURI = "pacecoach://localhost/strava"
    private let tokenStore = StravaTokenStore()
    private var session: ASWebAuthenticationSession?
    private var presentationContext: StravaPresentationContext?

    init() {
        do {
            if let tokens = try tokenStore.load() {
                isConnected = !tokens.refreshToken.isEmpty && tokens.grantsActivityWrite
            }
        } catch {
            errorMessage = "Could not read the saved Strava connection from Keychain."
        }
    }

    func connect() {
        guard !isConnecting else { return }
        errorMessage = nil

        guard !StravaCredentials.clientID.isEmpty,
              !StravaCredentials.clientSecret.isEmpty,
              !StravaCredentials.clientID.hasPrefix("YOUR_"),
              !StravaCredentials.clientSecret.hasPrefix("YOUR_") else {
            errorMessage = "Set your local Strava credentials, then rebuild the iPhone app."
            return
        }

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow) else {
            errorMessage = "Could not present Strava sign in. Reopen PaceCoach and try again."
            return
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            errorMessage = "Could not create a secure sign-in request."
            return
        }
        let expectedState = bytes.map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: StravaCredentials.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.callbackURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "activity:write"),
            URLQueryItem(name: "state", value: expectedState)
        ]
        guard let authorizationURL = components.url else {
            errorMessage = "Could not prepare Strava sign in."
            return
        }

        let context = StravaPresentationContext(window: window)
        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callback: .customScheme("pacecoach")
        ) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                await self?.finish(callbackURL: callbackURL, error: error, expectedState: expectedState)
            }
        }
        session.presentationContextProvider = context
        self.presentationContext = context
        self.session = session
        isConnecting = true
        if !session.start() {
            self.session = nil
            presentationContext = nil
            isConnecting = false
            errorMessage = "Could not open Strava sign in. Try again."
        }
    }

    func provisionWatch() {
        errorMessage = nil
        do {
            guard isConnected, let tokens = try tokenStore.load(),
                  !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
                  tokens.expiresAt > 0, tokens.grantsActivityWrite else {
                errorMessage = "Reconnect Strava on this iPhone before setting up the Watch."
                return
            }
            let payload = StravaProvisioningPayload(
                protocolVersion: StravaProvisioningPayload.protocolVersion,
                identifier: UUID(),
                sequence: try tokenStore.nextProvisioningSequence(),
                clientID: StravaCredentials.clientID,
                clientSecret: StravaCredentials.clientSecret,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresAt: tokens.expiresAt,
                scope: tokens.scope
            )
            guard payload.isValid else {
                errorMessage = "Local Strava configuration is incomplete."
                return
            }
            try CompanionConnectivity.shared.queueStravaProvisioning(payload)
        } catch StravaTokenStoreError.keychain {
            errorMessage = "Could not read the saved Strava connection from Keychain."
        } catch {
            errorMessage = "Could not queue Watch setup. Check that the Watch app is installed and try again."
        }
    }

    private func finish(callbackURL: URL?, error: Error?, expectedState: String) async {
        defer {
            session = nil
            presentationContext = nil
            isConnecting = false
        }

        guard let callbackURL else {
            let nsError = error as NSError?
            errorMessage = nsError?.domain == ASWebAuthenticationSessionErrorDomain
                && nsError?.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
                ? "Strava connection was cancelled."
                : "Strava sign in did not finish. Try again."
            return
        }
        guard let parts = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              parts.scheme == "pacecoach", parts.host == "localhost", parts.path == "/strava",
              parts.fragment == nil else {
            errorMessage = "Strava returned an unexpected callback."
            return
        }

        let items = parts.queryItems ?? []
        func uniqueValue(_ key: String) -> String? {
            let matches = items.filter { $0.name == key }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard uniqueValue("state") == expectedState else {
            errorMessage = "Strava sign-in state did not match. Try again."
            return
        }
        if let denial = uniqueValue("error") {
            errorMessage = denial == "access_denied"
                ? "Strava access was declined."
                : "Strava did not authorize this connection."
            return
        }
        guard let code = uniqueValue("code"), !code.isEmpty else {
            errorMessage = "Strava did not return an authorization code."
            return
        }
        guard let callbackScope = uniqueValue("scope"),
              Self.hasActivityWrite(callbackScope) else {
            errorMessage = "Strava did not grant activity upload access."
            return
        }

        do {
            let tokens = try await exchange(code: code)
            guard tokens.grantsActivityWrite else { throw StravaConnectionError.missingScope }
            try tokenStore.save(tokens)
            isConnected = true
            errorMessage = nil
            CompanionConnectivity.shared.invalidateStravaProvisioningStatus()
        } catch let error as URLError {
            errorMessage = "Strava is unreachable (network error \(error.code.rawValue)). Try again."
        } catch StravaConnectionError.http(let status) {
            errorMessage = "Strava rejected the connection (HTTP \(status)). Check the app settings and credentials."
        } catch StravaConnectionError.missingScope {
            errorMessage = "Strava did not grant activity upload access."
        } catch StravaTokenStoreError.keychain {
            errorMessage = "Strava authorized, but PaceCoach could not save the connection in Keychain."
        } catch {
            errorMessage = "Could not complete Strava connection. Try again."
        }
    }

    private func exchange(code: String) async throws -> StravaTokens {
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: StravaCredentials.clientID),
            URLQueryItem(name: "client_secret", value: StravaCredentials.clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        guard let encoded = body.percentEncodedQuery?.data(using: .utf8) else {
            throw StravaConnectionError.invalidResponse
        }
        request.httpBody = encoded
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StravaConnectionError.invalidResponse
        }
        guard http.statusCode == 200 else { throw StravaConnectionError.http(http.statusCode) }
        let tokens = try JSONDecoder().decode(StravaTokens.self, from: data)
        guard !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
              tokens.expiresAt > 0 else {
            throw StravaConnectionError.invalidResponse
        }
        return tokens
    }

    private static func hasActivityWrite(_ scopes: String) -> Bool {
        scopes.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .contains("activity:write")
    }
}

private enum StravaConnectionError: Error {
    case http(Int)
    case invalidResponse
    case missingScope
}

private final class StravaPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
