import SwiftUI

struct CompanionTestView: View {
    @ObservedObject private var connectivity = CompanionConnectivity.shared
    @State private var isTestingStrava = false
    @State private var stravaTestResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("iPhone Companion")
                    .font(.headline)
                Text(connectivity.status)
                    .font(.footnote)
                Text(connectivity.lastReceivedPing ?? "Waiting for a test message from iPhone.")
                    .font(.footnote)
                Text(connectivity.stravaProvisioningStatus)
                    .font(.footnote)
                Text("Development checks")
                    .font(.caption.bold())
                Button("Test Strava Connection") {
                    testStrava(forceRefresh: false)
                }
                .disabled(isTestingStrava)
                Button("Force Refresh (Development)") {
                    testStrava(forceRefresh: true)
                }
                .disabled(isTestingStrava)
                if let stravaTestResult {
                    Text(stravaTestResult)
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func testStrava(forceRefresh: Bool) {
        guard !isTestingStrava else { return }
        isTestingStrava = true
        stravaTestResult = "Checking Strava from Watch…"
        Task { @MainActor in
            defer { isTestingStrava = false }
            do {
                let token = try await WatchStravaTokenService.shared.validAccessToken(
                    forceRefresh: forceRefresh
                )
                if token.refreshTokenChanged {
                    stravaTestResult = "Token refreshed successfully"
                } else if token.refreshed {
                    stravaTestResult = "Refresh request succeeded; refresh token unchanged."
                } else {
                    stravaTestResult = "Strava connection valid"
                }
            } catch WatchStravaTokenError.notProvisioned {
                stravaTestResult = "Set up Strava from the iPhone first."
            } catch WatchStravaTokenError.httpStatus(let status) {
                stravaTestResult = status == 400 || status == 401
                    ? "Strava rejected the saved connection. Reconnect on iPhone."
                    : "Strava request failed (HTTP \(status)). Try again."
            } catch is URLError {
                stravaTestResult = "Watch could not reach Strava. Check its internet connection."
            } catch WatchStravaStoreError.keychain {
                stravaTestResult = "Could not save Watch tokens. Reconnect Strava on iPhone if retry fails."
            } catch {
                stravaTestResult = "Could not refresh Strava on Watch. Try again."
            }
        }
    }
}
