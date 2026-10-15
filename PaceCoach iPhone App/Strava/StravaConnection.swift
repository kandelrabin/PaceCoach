import AuthenticationServices
import Combine
import Foundation
import OSLog
import Security
import UIKit

@MainActor
final class StravaConnection: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String?

    private static let callbackURI = "pacecoach://localhost/strava"
    private let tokenStore = StravaTokenStore()
    private let logger = Logger(subsystem: "com.rabinkandel.PaceCoach", category: "StravaSetup")
    private var session: ASWebAuthenticationSession?
    private var presentationContext: StravaPresentationContext?

    init() {
        do {
            if let tokens = try tokenStore.load() {
                isConnected = !tokens.refreshToken.isEmpty && tokens.grantsActivityWrite
            }
        } catch {
            fail("Couldn’t read your saved Strava connection. Try connecting again.", diagnostic: "Saved connection could not be read")
        }
    }

    func connect(forceApproval: Bool = false) {
        guard !isConnecting else { return }
        errorMessage = nil

        guard !StravaCredentials.clientID.isEmpty,
              !StravaCredentials.clientSecret.isEmpty,
              !StravaCredentials.clientID.hasPrefix("YOUR_"),
              !StravaCredentials.clientSecret.hasPrefix("YOUR_") else {
            fail("Strava connection is currently unavailable. Try again later.", diagnostic: "Missing local OAuth configuration")
            return
        }

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow) else {
            fail("Couldn’t open Strava sign-in. Reopen PaceCoach and try again.", diagnostic: "No foreground presentation window")
            return
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fail("Couldn’t start Strava sign-in. Try again.", diagnostic: "Secure state generation failed")
            return
        }
        let expectedState = bytes.map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: StravaCredentials.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.callbackURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: forceApproval ? "force" : "auto"),
            URLQueryItem(name: "scope", value: "activity:write"),
            URLQueryItem(name: "state", value: expectedState)
        ]
        guard let authorizationURL = components.url else {
            fail("Couldn’t start Strava sign-in. Try again.", diagnostic: "Authorization URL could not be prepared")
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
            fail("Couldn’t open Strava sign-in. Try again.", diagnostic: "Authentication session did not start")
        }
    }

    func provisionWatch() {
        // Retry only when setup needs intervention; OAuth uses the fresh-handoff
        // path below after saving its new credentials.
        let presentation = StravaCompanionPresentation(isConnected: isConnected,
                                                       isConnecting: isConnecting,
                                                       watchSetup: CompanionConnectivity.shared.stravaSetupState)
        guard presentation.primaryAction == .retryWatchSetup else { return }
        queueWatchProvisioning()
    }

    private func queueWatchProvisioning() {
        errorMessage = nil
        do {
            guard isConnected, let tokens = try tokenStore.load(),
                  !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
                  tokens.expiresAt > 0, tokens.grantsActivityWrite else {
                fail("Reconnect to Strava on this iPhone, then try Watch setup again.", diagnostic: "Saved connection is missing or invalid")
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
                fail("Strava connection is currently unavailable. Try again later.", diagnostic: "Invalid Watch provisioning payload")
                return
            }
            try CompanionConnectivity.shared.queueStravaProvisioning(payload)
        } catch StravaTokenStoreError.keychain {
            fail("Couldn’t read your saved Strava connection. Try connecting again.", diagnostic: "Saved connection could not be read")
        } catch {
            fail("Couldn’t finish Apple Watch setup. Check that PaceCoach is installed on your paired Watch, then try again.", diagnostic: "Watch handoff could not be queued")
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
            let cancelled = nsError?.domain == ASWebAuthenticationSessionErrorDomain
                && nsError?.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
            fail(cancelled ? "Strava connection cancelled." : "Couldn’t complete Strava sign-in. Try again.",
                 diagnostic: cancelled ? "Authentication session cancelled" : "Authentication session returned no callback")
            return
        }
        guard let parts = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              parts.scheme == "pacecoach", parts.host == "localhost", parts.path == "/strava",
              parts.fragment == nil else {
            fail("Couldn’t complete Strava sign-in. Try again.", diagnostic: "Unexpected OAuth callback components")
            return
        }

        let items = parts.queryItems ?? []
        func uniqueValue(_ key: String) -> String? {
            let matches = items.filter { $0.name == key }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard uniqueValue("state") == expectedState else {
            fail("Couldn’t complete Strava sign-in. Try again.", diagnostic: "OAuth state mismatch")
            return
        }
        if let denial = uniqueValue("error") {
            fail(denial == "access_denied"
                 ? "Allow PaceCoach to upload activities when connecting to Strava."
                 : "Couldn’t complete Strava sign-in. Try again.",
                 diagnostic: "OAuth authorization was declined")
            return
        }
        guard let code = uniqueValue("code"), !code.isEmpty else {
            fail("Couldn’t complete Strava sign-in. Try again.", diagnostic: "OAuth code missing or duplicated")
            return
        }
        guard let callbackScope = uniqueValue("scope"),
              Self.hasActivityWrite(callbackScope) else {
            fail("Allow PaceCoach to upload activities when connecting to Strava.", diagnostic: "Upload permission was not granted")
            return
        }

        do {
            let tokens = try await exchange(code: code)
            guard tokens.grantsActivityWrite else { throw StravaConnectionError.missingScope }
            try tokenStore.save(tokens)
            isConnected = true
            errorMessage = nil
            CompanionConnectivity.shared.invalidateStravaProvisioningStatus()
            queueWatchProvisioning()
        } catch let error as URLError {
            fail("Couldn’t connect to Strava. Check your internet connection and try again.", diagnostic: "Token exchange network error \(error.code.rawValue)")
        } catch StravaConnectionError.http(let status) {
            fail("Couldn’t connect to Strava. Try again.", diagnostic: "Token exchange HTTP \(status)")
        } catch StravaConnectionError.missingScope {
            fail("Allow PaceCoach to upload activities when connecting to Strava.", diagnostic: "Upload permission was not granted")
        } catch StravaTokenStoreError.keychain {
            fail("Couldn’t save your Strava connection. Try connecting again.", diagnostic: "Authorized connection could not be saved")
        } catch {
            fail("Couldn’t complete Strava sign-in. Try again.", diagnostic: "Token exchange or storage failed (\(type(of: error)))")
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

    private func fail(_ message: String, diagnostic: String) {
        errorMessage = message
        // Only curated reasons/status codes: never URLs, response bodies, tokens,
        // callback parameters, or descriptions of errors that may contain them.
        logger.error("Strava setup: \(diagnostic, privacy: .public)")
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
