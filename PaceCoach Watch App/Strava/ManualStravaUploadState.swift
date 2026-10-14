import Foundation
import HealthKit

/// Selection is deliberately tied to both the saving app and its saved run ID.
enum PaceCoachSavedRunSelection {
    // Both IDs have been observed on saved PaceCoach Watch workouts.
    static let acceptedSourceBundleIDs: Set<String> = [
        "com.rabinkandel.PaceCoach.watchkitapp",
        "com.rabinkandel.PaceCoach"
    ]

    static func latest(in workouts: [HKWorkout], acceptedSourceBundleIDs: Set<String>) -> HKWorkout? {
        workouts.filter { workout in
            workout.workoutActivityType == .running &&
            acceptedSourceBundleIDs.contains(workout.sourceRevision.source.bundleIdentifier) &&
            workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool != true &&
            WorkoutRunIdentity.runID(in: workout) != nil
        }.max { left, right in
            if left.endDate != right.endDate { return left.endDate < right.endDate }
            return left.startDate < right.startDate
        }
    }
}

/// One run's foreground-only validation state. Once submission begins, this
/// instance never permits another POST, including after a network ambiguity.
struct ManualStravaUploadAttempt {
    enum Phase: Equatable {
        case notPrepared
        case preparationFailed
        case ready
        case submitting
        case accepted
        case processing
        case completed(Int64)
        case duplicate
        case failed
        case outcomeUnknown
    }

    private(set) var phase: Phase = .notPrepared
    private(set) var tcxFile: URL?
    private(set) var uploadID: String?

    var canPrepare: Bool { phase == .notPrepared || phase == .preparationFailed }
    var canSubmit: Bool { phase == .ready && tcxFile != nil && uploadID == nil }
    var canCheckStatus: Bool { uploadID != nil && phase != .submitting }

    mutating func prepared(file: URL) {
        guard canPrepare else { return }
        tcxFile = file
        phase = .ready
    }

    mutating func preparationFailed() {
        guard canPrepare else { return }
        phase = .preparationFailed
    }

    mutating func beginSubmission() -> Bool {
        guard canSubmit else { return false }
        phase = .submitting
        return true
    }

    mutating func submissionFailed(ambiguous: Bool, duplicate: Bool = false) {
        guard phase == .submitting else { return }
        phase = ambiguous ? .outcomeUnknown : duplicate ? .duplicate : .failed
    }

    mutating func receive(_ status: StravaUploadStatus) {
        guard phase == .submitting || uploadID == status.uploadID else { return }
        uploadID = status.uploadID
        switch status.state {
        case .accepted: phase = .accepted
        case .processing: phase = .processing
        case .completed(let activityID): phase = .completed(activityID)
        case .failed: phase = .failed
        case .duplicate: phase = .duplicate
        }
    }
}

