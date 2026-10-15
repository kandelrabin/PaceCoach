import Foundation
import CoreLocation
import HealthKit

/// Reads only samples associated with one saved workout. No coaching/profile
/// filtering, resampling, inferred timestamps, or synthetic missing values.
struct CompletedWorkoutDataReader {
    enum Stream {
        case heartRate
        case distanceWalkingRunning
        case runningSpeed

        var quantityType: HKQuantityType {
            switch self {
            case .heartRate: HKQuantityType(.heartRate)
            case .distanceWalkingRunning: HKQuantityType(.distanceWalkingRunning)
            case .runningSpeed: HKQuantityType(.runningSpeed)
            }
        }

        var unit: HKUnit {
            switch self {
            case .heartRate: HKUnit.count().unitDivided(by: .minute())
            case .distanceWalkingRunning: .meter()
            case .runningSpeed: HKUnit.meter().unitDivided(by: .second())
            }
        }
    }

    struct Observation {
        let sampleID: UUID
        let start: Date
        let end: Date
        // Distance values describe the measurement interval, not a cumulative
        // counter. Preserve them unchanged for future export normalization.
        let value: Double
    }

    let healthStore: HKHealthStore

    func read(_ stream: Stream, from workout: HKWorkout) async throws -> [Observation] {
        let type = stream.quantityType
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)]
        )
        let samples = try await query.result(for: healthStore)
        var observations: [Observation] = []

        for sample in samples {
            try Task.checkCancellation()
            if sample.count > 1 {
                let series = HKQuantitySeriesSampleQueryDescriptor(
                    predicate: .quantitySample(type: type, predicate: HKQuery.predicateForObject(with: sample.uuid))
                )
                let previousCount = observations.count
                for try await reading in series.results(for: healthStore) {
                    observations.append(Observation(
                        sampleID: sample.uuid,
                        start: reading.dateInterval.start,
                        end: reading.dateInterval.end,
                        value: reading.quantity.doubleValue(for: stream.unit)
                    ))
                }
                // Never substitute the parent aggregate for an unreadable series
                // or report partial data as a successfully read stream.
                guard observations.count > previousCount else {
                    throw ReadError.emptySeries(sample.uuid)
                }
            } else {
                observations.append(Observation(
                    sampleID: sample.uuid,
                    start: sample.startDate,
                    end: sample.endDate,
                    value: sample.quantity.doubleValue(for: stream.unit)
                ))
            }
        }

        observations.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        return observations
    }

    /// Reads every route associated with this workout. An absent route is an
    /// empty result; either the route lookup or point readback may throw.
    func readRoutes(from workout: HKWorkout) async throws -> [CLLocation] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\HKWorkoutRoute.startDate)]
        )
        let routes = try await query.result(for: healthStore).sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }
        var locations: [CLLocation] = []
        for route in routes {
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: healthStore) {
                try Task.checkCancellation()
                locations.append(location)
            }
        }
        return locations
    }

    private enum ReadError: LocalizedError {
        case emptySeries(UUID)

        var errorDescription: String? {
            switch self {
            case .emptySeries(let id): "Quantity series \(id) returned no observations."
            }
        }
    }
}
