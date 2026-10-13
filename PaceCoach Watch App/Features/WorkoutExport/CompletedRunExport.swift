import Foundation

/// A saved PaceCoach run after HealthKit and Core Location have been read.
/// Values remain in source precision; file-format scaling belongs to an encoder.
struct CompletedRunExport {
    enum Activity {
        case outdoorRun
    }

    /// One actual quantity reading. The source sample UUID distinguishes
    /// legitimate same-time readings from a repeated query result.
    struct Measurement: Hashable {
        let sourceSampleID: UUID
        let start: Date
        let end: Date
        let value: Double
    }

    struct RoutePoint: Hashable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double?
        let horizontalAccuracyMeters: Double?
        let verticalAccuracyMeters: Double?
        let gpsSpeedMetersPerSecond: Double?
        let courseDegrees: Double?
    }

    /// PaceCoach's stable identity; healthKitWorkoutID identifies its saved copy.
    let runID: UUID
    let healthKitWorkoutID: UUID
    let activity: Activity
    let start: Date
    let end: Date
    var elapsedDurationSeconds: TimeInterval { end.timeIntervalSince(start) }
    let activeDurationSeconds: TimeInterval?
    let timeZoneIdentifier: String?
    let totalDistanceMeters: Double?
    let heartRateBPM: [Measurement]
    /// Interval deltas, never an inferred cumulative distance track.
    let distanceDeltasMeters: [Measurement]
    let runningSpeedMetersPerSecond: [Measurement]
    let routePoints: [RoutePoint]
}

/// Pure ordering at the export boundary; no merging or resampling.
enum CompletedRunExportOrdering {
    static func measurements(_ readings: [CompletedRunExport.Measurement]) -> [CompletedRunExport.Measurement] {
        var seen = Set<CompletedRunExport.Measurement>()
        return readings.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.sourceSampleID != $1.sourceSampleID {
                return $0.sourceSampleID.uuidString < $1.sourceSampleID.uuidString
            }
            return $0.value < $1.value
        }.filter { seen.insert($0).inserted }
    }

    static func routePoints(_ points: [CompletedRunExport.RoutePoint]) -> [CompletedRunExport.RoutePoint] {
        var seen = Set<CompletedRunExport.RoutePoint>()
        return points.sorted(by: routePointLess).filter { seen.insert($0).inserted }
    }

    nonisolated private static func routePointLess(
        _ left: CompletedRunExport.RoutePoint,
        _ right: CompletedRunExport.RoutePoint
    ) -> Bool {
        if left.timestamp != right.timestamp { return left.timestamp < right.timestamp }
        let leftValues: [Double?] = [
            left.latitude, left.longitude, left.altitudeMeters,
            left.horizontalAccuracyMeters, left.verticalAccuracyMeters,
            left.gpsSpeedMetersPerSecond, left.courseDegrees
        ]
        let rightValues: [Double?] = [
            right.latitude, right.longitude, right.altitudeMeters,
            right.horizontalAccuracyMeters, right.verticalAccuracyMeters,
            right.gpsSpeedMetersPerSecond, right.courseDegrees
        ]
        for (a, b) in zip(leftValues, rightValues) {
            switch (a, b) {
            case (nil, nil): continue
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?):
                if a != b { return a < b }
            }
        }
        return false
    }
}
