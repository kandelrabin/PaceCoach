import Combine
import Foundation
import HealthKit

@MainActor
final class ManualStravaUploadFlow: ObservableObject {
    static let shared = ManualStravaUploadFlow()

    @Published private(set) var selectedWorkout: HKWorkout?
    @Published private(set) var selectedRunID: UUID?
    @Published private(set) var upload: PendingStravaUpload?
    @Published private(set) var routeDiagnostic: WorkoutRouteDiagnostic?
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
                routeDiagnostic = nil
                tcxFile = nil
                message = "No saved outdoor PaceCoach run is available in Health."
                return
            }
            guard let store else { throw PendingStravaUploadStore.StoreError.documentsUnavailable }
            let record = try store.loadOrCreate(runID: runID)
            selectedWorkout = workout
            selectedRunID = runID
            upload = record
            routeDiagnostic = (try? WorkoutRouteDiagnosticStore())?.load(runID: runID)
            tcxFile = nil
            message = "Saved run selected."
        } catch {
            selectedWorkout = nil
            selectedRunID = nil
            upload = nil
            routeDiagnostic = nil
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
              upload?.isPostEligible == true, let store else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Preparing Strava request…"
        let result = await AutomaticStravaUploadFlow.shared.submitManually(runID: runID, tcxFile: file)
        // Retain an accepted response in memory even if its durable write failed.
        upload = result.record ?? (try? store.load(runID: runID))
        message = result.message
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
            #if DEBUG
            AutomaticStravaUploadFlow.shared.traceStatusResponse(runID: current.runID, record: updated, response: status)
            #endif
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
