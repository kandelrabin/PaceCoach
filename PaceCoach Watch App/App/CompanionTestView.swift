import HealthKit
import SwiftUI

struct CompanionTestView: View {
    @ObservedObject private var connectivity = CompanionConnectivity.shared
    @ObservedObject private var manualUpload = ManualStravaUploadFlow.shared
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

                Divider()
                Text("Manual Strava upload test")
                    .font(.caption.bold())
                Button("Find Latest PaceCoach Run") {
                    Task { await manualUpload.findLatest() }
                }
                .disabled(manualUpload.isBusy)
                if let workout = manualUpload.selectedWorkout,
                   let runID = manualUpload.selectedRunID {
                    Text("Selected outdoor run")
                        .font(.caption.bold())
                    Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                    Text("Run ID: \(runID.uuidString.lowercased())")
                        .font(.caption2)
                    Button("Prepare TCX") {
                        Task { await manualUpload.prepareTCX() }
                    }
                    .disabled(manualUpload.isBusy || !manualUpload.attempt.canPrepare)
                }
                if manualUpload.attempt.tcxFile != nil {
                    Text("TCX prepared")
                        .font(.footnote)
                    Button("Upload Selected TCX to Strava") {
                        Task { await manualUpload.submit() }
                    }
                    .disabled(manualUpload.isBusy || !manualUpload.attempt.canSubmit)
                }
                if let uploadID = manualUpload.attempt.uploadID {
                    Text("Strava upload ID: \(uploadID)")
                        .font(.caption2)
                    Button("Check Status") {
                        Task { await manualUpload.checkStatus() }
                    }
                    .disabled(manualUpload.isBusy || !manualUpload.attempt.canCheckStatus)
                }
                if manualUpload.selectedRunID != nil {
                    Text(uploadStateText)
                        .font(.footnote)
                }
                if let message = manualUpload.message {
                    Text(message)
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var uploadStateText: String {
        switch manualUpload.attempt.phase {
        case .notPrepared: "TCX not prepared"
        case .preparationFailed: "TCX preparation failed"
        case .ready: "TCX ready; upload has not started"
        case .submitting: "Upload request in progress"
        case .accepted: "Strava accepted the upload; processing may continue"
        case .processing: "Strava is processing the upload"
        case .completed(let activityID): "Completed: Strava activity ID \(activityID)"
        case .duplicate: "Strava reported a duplicate"
        case .failed: "Strava upload failed"
        case .outcomeUnknown: "Upload outcome unknown; do not resubmit"
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
