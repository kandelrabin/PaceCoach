import CoreLocation
import Foundation
import HealthKit

// Run with the four export/reader/identity sources and HealthKit/CoreLocation
// frameworks, as in the Stage 3 verification command.
@main
struct CompletedRunExportChecks {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    private static var checks = 0

    static func main() async throws {
        try await identityAndActivity()
        quantityUnits()
        measurementOrdering()
        try routeMappingAndOrdering()
        missingDataAndTiming()
        print("Completed run export checks passed (\(checks) assertions)")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    private static func identityAndActivity() async throws {
        let runID = UUID()
        // Deprecated constructors are used only to make read-only fixtures;
        // HKWorkoutBuilder would require a live authorized HealthKit store.
        let running = HKWorkout(
            activityType: .running, start: epoch, end: epoch.addingTimeInterval(60),
            workoutEvents: nil, totalEnergyBurned: nil, totalDistance: nil,
            metadata: [WorkoutRunIdentity.metadataKey: runID.uuidString]
        )
        check(WorkoutRunIdentity.runID(in: running) == runID, "Saved run UUID is recovered")
        let builder = CompletedRunExportBuilder(healthStore: HKHealthStore())
        let cycling = HKWorkout(activityType: .cycling, start: epoch, end: epoch.addingTimeInterval(60))
        do {
            _ = try await builder.build(from: cycling)
            preconditionFailure("Non-running workout was accepted")
        } catch CompletedRunExportBuilder.ExportError.notRunning {
            checks += 1
        }
        let unidentified = HKWorkout(activityType: .running, start: epoch, end: epoch.addingTimeInterval(60))
        do {
            _ = try await builder.build(from: unidentified)
            preconditionFailure("Workout without run UUID was accepted")
        } catch CompletedRunExportBuilder.ExportError.missingRunID {
            checks += 1
        }
        check(WorkoutRunIdentity.runID(in: unidentified) == nil, "Missing identity stays missing")
        check(CompletedRunExportBuilder.totalDistanceMeters(from: unidentified) == nil,
              "No workout distance summary stays missing")
        let withDistance = HKWorkout(
            activityType: .running, start: epoch, end: epoch.addingTimeInterval(60),
            workoutEvents: nil, totalEnergyBurned: nil,
            totalDistance: HKQuantity(unit: .meter(), doubleValue: 234), metadata: nil
        )
        check(CompletedRunExportBuilder.totalDistanceMeters(from: withDistance) == 234,
              "Workout summary distance is retained in metres")
    }

    private static func quantityUnits() {
        let mile = HKQuantity(unit: .mile(), doubleValue: 1)
        let metres = mile.doubleValue(for: CompletedWorkoutDataReader.Stream.distanceWalkingRunning.unit)
        check(abs(metres - 1_609.344) < 0.000_001, "Distance is canonical metres")
        let beatsPerSecond = HKQuantity(
            unit: HKUnit.count().unitDivided(by: .second()), doubleValue: 2
        )
        let bpm = beatsPerSecond.doubleValue(for: CompletedWorkoutDataReader.Stream.heartRate.unit)
        check(abs(bpm - 120) < 0.000_001, "Heart rate is canonical bpm")
        let speed = HKQuantity(unit: HKUnit.mile().unitDivided(by: .hour()), doubleValue: 6)
        let metresPerSecond = speed.doubleValue(for: CompletedWorkoutDataReader.Stream.runningSpeed.unit)
        check(abs(metresPerSecond - 2.68224) < 0.000_001, "Speed is canonical metres per second")
    }

    private static func measurementOrdering() {
        let firstID = UUID()
        let secondID = UUID()
        let first = CompletedRunExport.Measurement(
            sourceSampleID: firstID, start: epoch, end: epoch.addingTimeInterval(1), value: 130
        )
        let sameTimeDistinct = CompletedRunExport.Measurement(
            sourceSampleID: secondID, start: epoch, end: epoch.addingTimeInterval(1), value: 130
        )
        let afterGap = CompletedRunExport.Measurement(
            sourceSampleID: firstID, start: epoch.addingTimeInterval(60),
            end: epoch.addingTimeInterval(61), value: 145
        )
        let result = CompletedRunExportOrdering.measurements([
            afterGap, first, sameTimeDistinct, first
        ])
        check(result.count == 3, "Only the exact repeated reading is removed")
        check(Set(result.prefix(2).map(\.sourceSampleID)) == [firstID, secondID],
              "Distinct same-time sources are retained")
        check(result.last == afterGap, "Readings sort chronologically")
        check(result[2].start.timeIntervalSince(result[1].end) >= 59,
              "A sensor gap is preserved")
        check(result == CompletedRunExportOrdering.measurements(result.reversed()),
              "Ordering is independent of source query order")
    }

    private static func routeMappingAndOrdering() throws {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
            altitude: 42, horizontalAccuracy: 5, verticalAccuracy: 7,
            course: 90, speed: 3, timestamp: epoch
        )
        let point = try CompletedRunExportBuilder.routePoint(location)
        check(point.timestamp == epoch && point.latitude == 51.5 && point.longitude == -0.12,
              "Route timestamp and coordinates are retained")
        check(point.altitudeMeters == 42 && point.horizontalAccuracyMeters == 5 &&
              point.verticalAccuracyMeters == 7 && point.gpsSpeedMetersPerSecond == 3 &&
              point.courseDegrees == 90, "Available route measurements are retained")
        let missing = CLLocation(
            coordinate: location.coordinate, altitude: 42, horizontalAccuracy: -1,
            verticalAccuracy: -1, course: -1, speed: -1,
            timestamp: epoch.addingTimeInterval(30)
        )
        let missingPoint = try CompletedRunExportBuilder.routePoint(missing)
        check(missingPoint.altitudeMeters == nil && missingPoint.horizontalAccuracyMeters == nil &&
              missingPoint.verticalAccuracyMeters == nil && missingPoint.gpsSpeedMetersPerSecond == nil &&
              missingPoint.courseDegrees == nil, "Unavailable route fields remain missing")
        let sameTimeDifferentAltitude = CompletedRunExport.RoutePoint(
            timestamp: point.timestamp, latitude: point.latitude, longitude: point.longitude,
            altitudeMeters: 43, horizontalAccuracyMeters: point.horizontalAccuracyMeters,
            verticalAccuracyMeters: point.verticalAccuracyMeters,
            gpsSpeedMetersPerSecond: point.gpsSpeedMetersPerSecond,
            courseDegrees: point.courseDegrees
        )
        let ordered = CompletedRunExportOrdering.routePoints([
            missingPoint, point, point, sameTimeDifferentAltitude
        ])
        check(ordered.count == 3, "Only fully identical route points are removed")
        check(ordered[0].timestamp == epoch && ordered[2].timestamp == missingPoint.timestamp,
              "Route points sort chronologically without filling the gap")
        check(ordered == CompletedRunExportOrdering.routePoints(ordered.reversed()),
              "Route ordering is deterministic")
    }

    private static func missingDataAndTiming() {
        let export = CompletedRunExport(
            runID: UUID(), healthKitWorkoutID: UUID(), activity: .outdoorRun,
            start: epoch, end: epoch.addingTimeInterval(70),
            activeDurationSeconds: nil, timeZoneIdentifier: nil, totalDistanceMeters: nil,
            heartRateBPM: [], distanceDeltasMeters: [],
            runningSpeedMetersPerSecond: [], routePoints: []
        )
        check(export.elapsedDurationSeconds == 70 && export.activeDurationSeconds == nil,
              "Absolute times preserve elapsed time without inventing active time")
        check(export.totalDistanceMeters == nil && export.heartRateBPM.isEmpty &&
              export.distanceDeltasMeters.isEmpty && export.runningSpeedMetersPerSecond.isEmpty &&
              export.routePoints.isEmpty, "Every optional stream can be genuinely missing")
        check(export.timeZoneIdentifier == nil, "No timezone is invented")
    }
}
