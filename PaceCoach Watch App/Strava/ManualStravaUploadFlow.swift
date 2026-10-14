import Combine
import Foundation
import HealthKit

@MainActor
final class ManualStravaUploadFlow: ObservableObject {
    static let shared = ManualStravaUploadFlow()

    @Published private(set) var selectedWorkout: HKWorkout?
    @Published private(set) var selectedRunID: UUID?
    @Published private(set) var attempt = ManualStravaUploadAttempt()
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    private let healthStore = HealthKitAuthorization.healthStore
    private var attemptsByRunID: [UUID: ManualStravaUploadAttempt] = [:]

    func findLatest() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Finding saved PaceCoach runs…"
        do {
            try await HealthKitAuthorization.ensureAuthorized(for: .targetPaceWorkout)
            try await HealthKitAuthorization.ensureAuthorized(for: .workoutRoute)
            let workouts = try await savedRunningWorkouts()
            guard let workout = PaceCoachSavedRunSelection.latest(
                    in: workouts, acceptedSourceBundleIDs: PaceCoachSavedRunSelection.acceptedSourceBundleIDs
                  ),
                  let runID = WorkoutRunIdentity.runID(in: workout) else {
                selectedWorkout = nil
                selectedRunID = nil
                attempt = ManualStravaUploadAttempt()
                message = "No saved outdoor PaceCoach run is available in Health."
                return
            }
            selectedWorkout = workout
            selectedRunID = runID
            attempt = attemptsByRunID[runID] ?? ManualStravaUploadAttempt()
            message = "Saved run selected."
        } catch {
            selectedWorkout = nil
            selectedRunID = nil
            attempt = ManualStravaUploadAttempt()
            message = "Could not read saved workouts. Check Health permissions and try again."
        }
    }

    func prepareTCX() async {
        guard !isBusy, let workout = selectedWorkout, let runID = selectedRunID,
              attempt.canPrepare else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Preparing TCX from saved workout…"
        do {
            let run = try await CompletedRunExportBuilder(healthStore: healthStore).build(from: workout)
            guard run.runID == runID else {
                throw StravaUploadError.invalidResponse
            }
            let tcx = try TCXActivityEncoder().encode(run)
            let file = try TCXExportFileWriter().write(tcx.data, runID: runID)
            attempt.prepared(file: file)
            rememberAttempt()
            message = "TCX prepared: \(tcx.trackpointCount) trackpoints."
        } catch {
            attempt.preparationFailed()
            rememberAttempt()
            message = "TCX preparation failed. The saved workout is unchanged."
        }
    }

    func submit() async {
        guard !isBusy, let runID = selectedRunID, let file = attempt.tcxFile,
              attempt.beginSubmission() else { return }
        rememberAttempt()
        isBusy = true
        defer { isBusy = false }
        message = "Submitting TCX to Strava…"
        do {
            attempt.receive(try await WatchStravaUploadService.shared.upload(tcxFile: file, runID: runID))
            rememberAttempt()
            message = "Strava responded. Check status manually if processing continues."
        } catch {
            let uploadError = error as? StravaUploadError
            let ambiguous: Bool
            switch uploadError {
            case .network, .invalidResponse: ambiguous = true
            case .httpStatus(let code): ambiguous = code >= 500
            default: ambiguous = false
            }
            attempt.submissionFailed(ambiguous: ambiguous,
                                     duplicate: uploadError == .duplicate)
            rememberAttempt()
            message = ambiguous
                ? "Outcome unknown: the request may have reached Strava. Do not submit this run again."
                : uploadError == .duplicate
                    ? "Strava reported a duplicate. This run will not be resubmitted here."
                    : "Submission failed. This run will not be resubmitted in this validation flow."
        }
    }

    func checkStatus() async {
        guard !isBusy, attempt.canCheckStatus, let uploadID = attempt.uploadID else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Checking Strava processing status…"
        do {
            attempt.receive(try await WatchStravaUploadService.shared.checkStatus(uploadID: uploadID))
            rememberAttempt()
            message = "Strava status updated."
        } catch {
            message = "Could not check Strava status. Use Check Status again later; no TCX was reposted."
        }
    }

    private func rememberAttempt() {
        if let selectedRunID { attemptsByRunID[selectedRunID] = attempt }
    }

    private func savedRunningWorkouts() async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForWorkouts(with: .running),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKWorkout })
                }
            }
            healthStore.execute(query)
        }
    }
}
