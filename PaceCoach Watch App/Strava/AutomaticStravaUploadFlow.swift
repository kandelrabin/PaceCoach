import Foundation
import HealthKit

/// An immediate, best-effort attempt owned by the process rather than a view.
/// The ledger is authoritative; a suspended or killed process has no retry task.
@MainActor
final class AutomaticStravaUploadFlow {
    private let store: PendingStravaUploadStore?
    private let makeTCX: (HKWorkout, UUID) async throws -> URL
    private let prepareRequest: (URL, UUID) async throws -> URLRequest
    private let preflight: () async throws -> Void
    private let submitRequest: (URLRequest) async throws -> StravaUploadStatus
    private var attemptedRunIDs = Set<UUID>()

    init(
        store: PendingStravaUploadStore?,
        makeTCX: @escaping (HKWorkout, UUID) async throws -> URL,
        prepareRequest: @escaping (URL, UUID) async throws -> URLRequest,
        preflight: @escaping () async throws -> Void,
        submitRequest: @escaping (URLRequest) async throws -> StravaUploadStatus
    ) {
        self.store = store
        self.makeTCX = makeTCX
        self.prepareRequest = prepareRequest
        self.preflight = preflight
        self.submitRequest = submitRequest
    }

    /// Called only after finishWorkout and finishRoute have returned. Registration
    /// is synchronous so End Run can leave with a durable pending record.
    @discardableResult
    func registerAndStart(savedWorkout: HKWorkout, runID: UUID) -> Task<Void, Never>? {
        guard WorkoutRunIdentity.runID(in: savedWorkout) == runID,
              let store, !attemptedRunIDs.contains(runID) else { return nil }
        let record: PendingStravaUpload
        do {
            record = try store.loadOrCreate(runID: runID)
        } catch {
            return nil
        }
        guard record.isPostEligible else { return nil }
        attemptedRunIDs.insert(runID)
        return Task { [self] in
            await attempt(savedWorkout: savedWorkout, runID: runID)
        }
    }

    private func attempt(savedWorkout: HKWorkout, runID: UUID) async {
        guard let store else { return }
        // Export, token preparation, and the read-only probe precede submitting.
        let request: URLRequest
        do {
            let file = try await makeTCX(savedWorkout, runID)
            request = try await prepareRequest(file, runID)
            try await preflight()
        } catch {
            do {
                guard var current = try store.load(runID: runID), current.isPostEligible else { return }
                current.preRequestFailed()
                try store.save(current)
            } catch { }
            return
        }

        // Re-read after every suspension point. The manual screen may have
        // changed this same record while TCX or token preparation was running.
        var current: PendingStravaUpload
        do {
            guard let latest = try store.load(runID: runID), latest.isPostEligible else { return }
            current = latest
            guard current.beginSubmission() else { return }
            try store.save(current)
        } catch {
            return // No POST unless the in-flight marker is durable.
        }

        do {
            let status = try await submitRequest(request)
            current.receive(status)
        } catch {
            switch error as? StravaUploadError {
            case .duplicate: current.rejected(duplicate: true)
            case .httpStatus(let code) where code >= 400 && code < 500:
                current.rejected(duplicate: false)
            default: current.postOutcomeUnknown()
            }
        }
        // If this write fails, the persisted submitting marker recovers as
        // outcomeUnknown. The saved HealthKit workout is never touched.
        try? store.save(current)
    }
}
