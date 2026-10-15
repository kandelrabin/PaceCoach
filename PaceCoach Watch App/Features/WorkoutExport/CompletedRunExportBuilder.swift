import CoreLocation
import Foundation
import HealthKit

/// Read-only adapter from a saved HealthKit workout to an encoder-ready value.
struct CompletedRunExportBuilder {
    enum ExportError: LocalizedError {
        case notRunning
        case indoorWorkout
        case missingRunID
        case invalidTimeRange
        case invalidMeasurement(UUID)
        case invalidRouteCoordinate

        var errorDescription: String? {
            switch self {
            case .notRunning: "The saved workout is not a run."
            case .indoorWorkout: "The saved workout is marked as indoor."
            case .missingRunID: "The saved workout has no PaceCoach run ID."
            case .invalidTimeRange: "The saved workout has an invalid time range."
            case .invalidMeasurement(let id): "The saved workout has an invalid quantity reading in sample \(id)."
            case .invalidRouteCoordinate: "The saved workout route contains an invalid coordinate."
            }
        }
    }

    let reader: CompletedWorkoutDataReader

    init(healthStore: HKHealthStore) {
        reader = CompletedWorkoutDataReader(healthStore: healthStore)
    }

    func build(from workout: HKWorkout) async throws -> CompletedRunExport {
        guard workout.workoutActivityType == .running else { throw ExportError.notRunning }
        // PaceCoach currently records only outdoor runs. Do not infer outdoor
        // status from route presence: location permission can be denied.
        guard workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool != true else {
            throw ExportError.indoorWorkout
        }
        guard let runID = WorkoutRunIdentity.runID(in: workout) else {
            throw ExportError.missingRunID
        }
        guard workout.endDate >= workout.startDate else { throw ExportError.invalidTimeRange }

        let heartRate = try await reader.read(.heartRate, from: workout)
        let distance = try await reader.read(.distanceWalkingRunning, from: workout)
        let speed = try await reader.read(.runningSpeed, from: workout)
        let locations = try await reader.readRoutes(from: workout)

        let timeZoneID = workout.metadata?[HKMetadataKeyTimeZone] as? String
        let validTimeZoneID = timeZoneID.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }

        return CompletedRunExport(
            runID: runID,
            healthKitWorkoutID: workout.uuid,
            activity: .outdoorRun,
            start: workout.startDate,
            end: workout.endDate,
            activeDurationSeconds: Self.usableNonnegative(workout.duration),
            timeZoneIdentifier: validTimeZoneID,
            totalDistanceMeters: Self.totalDistanceMeters(from: workout),
            heartRateBPM: try measurements(from: heartRate),
            distanceDeltasMeters: try measurements(from: distance),
            runningSpeedMetersPerSecond: try measurements(from: speed),
            routePoints: try CompletedRunExportOrdering.routePoints(locations.map(Self.routePoint))
        )
    }

    static func totalDistanceMeters(from workout: HKWorkout) -> Double? {
        let quantity = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()
        return quantity.map { $0.doubleValue(for: .meter()) }.flatMap(usableNonnegative)
    }

    private func measurements(
        from observations: [CompletedWorkoutDataReader.Observation]
    ) throws -> [CompletedRunExport.Measurement] {
        let mapped = try observations.map { observation in
            guard Self.usableNonnegative(observation.value) != nil else {
                throw ExportError.invalidMeasurement(observation.sampleID)
            }
            return CompletedRunExport.Measurement(
                sourceSampleID: observation.sampleID,
                start: observation.start,
                end: observation.end,
                value: observation.value
            )
        }
        return CompletedRunExportOrdering.measurements(mapped)
    }

    static func routePoint(_ location: CLLocation) throws -> CompletedRunExport.RoutePoint {
        let coordinate = location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            throw ExportError.invalidRouteCoordinate
        }
        let verticalAccuracy = usableNonnegative(location.verticalAccuracy)
        return CompletedRunExport.RoutePoint(
            timestamp: location.timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitudeMeters: verticalAccuracy == nil ? nil : usableFinite(location.altitude),
            horizontalAccuracyMeters: usableNonnegative(location.horizontalAccuracy),
            verticalAccuracyMeters: verticalAccuracy,
            gpsSpeedMetersPerSecond: usableNonnegative(location.speed),
            courseDegrees: usableNonnegative(location.course).flatMap { $0 <= 360 ? $0 : nil }
        )
    }

    private static func usableFinite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    nonisolated private static func usableNonnegative(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }
}
