import Foundation
import HealthKit

/// Selection is tied to both the saving app and its saved run ID.
enum PaceCoachSavedRunSelection {
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
