import Combine
import Foundation
import HealthKit

@MainActor
final class ManualStravaUploadFlow: ObservableObject {
    static let shared = ManualStravaUploadFlow()

    @Published private(set) var selectedWorkout: HKWorkout?
    @Published private(set) var selectedRunID: UUID?
    @Published private(set) var upload: PendingStravaUpload?
    @Published private(set) var tcxFile: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    private let healthStore = HealthKitAuthorization.healthStore
    private let store: PendingStravaUploadStore?

    private init() {
        store = try? PendingStravaUploadStore()
    }

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
                  ), let runID = WorkoutRunIdentity.runID(in: workout) else {
                selectedWorkout = nil
                selectedRunID = nil
                upload = nil
                tcxFile = nil
                message = "No saved outdoor PaceCoach run is available in Health."
                return
            }
            guard let store else { throw PendingStravaUploadStore.StoreError.documentsUnavailable }
            let record = try store.loadOrCreate(runID: runID)
            selectedWorkout = workout
            selectedRunID = runID
            upload = record
            tcxFile = nil
            message = "Saved run selected."
        } catch {
            selectedWorkout = nil
            selectedRunID = nil
            upload = nil
            tcxFile = nil
            message = "Could not read the saved run or its upload state. No upload is allowed."
        }
    }

    func prepareTCX() async {
        guard !isBusy, let workout = selectedWorkout, let runID = selectedRunID,
              upload?.isPostEligible == true else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Preparing TCX from saved workout…"
        do {
            let run = try await CompletedRunExportBuilder(healthStore: healthStore).build(from: workout)
            guard run.runID == runID else { throw StravaUploadError.invalidResponse }
            let tcx = try TCXActivityEncoder().encode(run)
            tcxFile = try TCXExportFileWriter().write(tcx.data, runID: runID)
            message = "TCX prepared: \(tcx.trackpointCount) trackpoints."
        } catch {
            tcxFile = nil
            message = "TCX preparation failed. The saved workout is unchanged."
        }
    }

    func submit() async {
        guard !isBusy, let runID = selectedRunID, let file = tcxFile,
              let current = upload, current.isPostEligible, let store else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Preparing Strava request…"

        // File read, token refresh, and request construction happen before the
        // durable submitting state. Failures here cannot create an upload.
        let request: URLRequest
        do {
            request = try await WatchStravaUploadService.shared.prepareUpload(tcxFile: file, runID: runID)
        } catch {
            var failed = current
            failed.preRequestFailed()
            do { try store.save(failed); upload = failed }
            catch { message = "Could not save upload state. No request was sent."; return }
            message = "Request preparation failed before POST. Retry is safe."
            return
        }

        var submitting = current
        guard submitting.beginSubmission() else { return }
        do {
            try store.save(submitting)
            upload = submitting
        } catch {
            message = "Could not save upload state. No request was sent."
            return
        }
        message = "Submitting TCX to Strava…"
        let status: StravaUploadStatus
        do {
            status = try await WatchStravaUploadService.shared.submitPrepared(request)
        } catch {
            let uploadError = error as? StravaUploadError
            // A received 4xx rejection is terminal. A transport failure,
            // malformed success response, or 5xx may hide an accepted POST.
            switch uploadError {
            case .duplicate: submitting.rejected(duplicate: true)
            case .httpStatus(let code) where code >= 400 && code < 500:
                submitting.rejected(duplicate: false)
            default: submitting.postOutcomeUnknown()
            }
            do {
                try store.save(submitting)
                upload = submitting
                message = submitting.phase == .outcomeUnknown
                    ? "Outcome unknown: the request may have reached Strava. Do not submit again."
                    : "Strava rejected the upload. This run will not be resubmitted."
            } catch {
                // The durable submitting record is still conservative on relaunch.
                upload = submitting
                message = "Could not save Strava's result. Do not submit again."
            }
            return
        }

        submitting.receive(status)
        upload = submitting
        do {
            try store.save(submitting)
            upload = submitting
            message = "Strava responded. Check status manually if processing continues."
        } catch {
            // Retain the accepted ID in memory. The durable submitting record
            // becomes outcome unknown on relaunch if this write never succeeds.
            message = "Strava responded, but its result could not be saved. Do not submit again."
        }
    }

    func checkStatus() async {
        guard !isBusy, let current = upload, current.canCheckStatus,
              let uploadID = current.uploadID, let store else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Checking Strava processing status…"
        do {
            let status = try await WatchStravaUploadService.shared.checkStatus(uploadID: uploadID)
            var updated = current
            updated.receive(status)
            try store.save(updated)
            upload = updated
            message = "Strava status updated."
        } catch {
            message = "Could not save or check Strava status. Check again later; no TCX was reposted."
        }
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
