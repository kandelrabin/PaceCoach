import Foundation
import HealthKit

extension AutomaticStravaUploadFlow {
    static let shared = AutomaticStravaUploadFlow(
        store: try? PendingStravaUploadStore(),
        makeTCX: { workout, runID in
            let run = try await CompletedRunExportBuilder(
                healthStore: HealthKitAuthorization.healthStore
            ).build(from: workout)
            guard run.runID == runID else { throw StravaUploadError.invalidResponse }
            // Exporting a backlog must not occupy the workout/UI actor.
            return try await Task.detached(priority: .utility) {
                let tcx = try TCXActivityEncoder().encode(run)
                return try TCXExportFileWriter().write(tcx.data, runID: runID)
            }.value
        },
        prepareRequest: { file, runID in
            try await WatchStravaUploadService.shared.prepareUpload(tcxFile: file, runID: runID)
        },
        preflight: {
            try await WatchStravaUploadService.shared.checkUploadPreflight()
        },
        submitRequest: { request in
            try await WatchStravaUploadService.shared.submitPrepared(request)
        },
        resolveWorkouts: { runIDs in
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForWorkouts(with: .running),
                HKQuery.predicateForObjects(
                    withMetadataKey: WorkoutRunIdentity.metadataKey,
                    allowedValues: runIDs.flatMap { [$0.uuidString, $0.uuidString.lowercased()] }
                )
            ])
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: HKObjectType.workoutType(), predicate: predicate,
                    limit: HKObjectQueryNoLimit, sortDescriptors: nil
                ) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKWorkout }) }
                }
                HealthKitAuthorization.healthStore.execute(query)
            }
        },
        initiallyActive: false
    )
}
