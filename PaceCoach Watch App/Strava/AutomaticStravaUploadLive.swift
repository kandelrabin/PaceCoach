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
            let tcx = try TCXActivityEncoder().encode(run)
            return try TCXExportFileWriter().write(tcx.data, runID: runID)
        },
        prepareRequest: { file, runID in
            try await WatchStravaUploadService.shared.prepareUpload(tcxFile: file, runID: runID)
        },
        preflight: {
            try await WatchStravaUploadService.shared.checkUploadPreflight()
        },
        submitRequest: { request in
            try await WatchStravaUploadService.shared.submitPrepared(request)
        }
    )
}
