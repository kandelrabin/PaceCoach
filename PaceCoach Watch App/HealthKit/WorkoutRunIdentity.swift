import Foundation
import HealthKit

enum WorkoutRunIdentity {
    // Custom HealthKit metadata supports String values. Keep this key stable:
    // the saved workout itself persists the run ID alongside its HealthKit UUID.
    static let metadataKey = "com.rabinkandel.PaceCoach.runID"

    static func runID(in workout: HKWorkout) -> UUID? {
        guard let value = workout.metadata?[metadataKey] as? String else { return nil }
        return UUID(uuidString: value)
    }
}
