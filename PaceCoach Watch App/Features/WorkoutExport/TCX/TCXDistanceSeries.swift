import Foundation

/// Converts HealthKit distance *interval deltas* to values at their actual end
/// timestamps. A nil result means the entire series is unsafe to accumulate.
enum TCXDistanceSeries {
    struct Point: Equatable {
        let timestamp: Date
        let cumulativeMeters: Double
    }

    static func cumulativePoints(
        from readings: [CompletedRunExport.Measurement],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [Point]? {
        guard !readings.isEmpty else { return [] }
        guard readings.allSatisfy({ $0.value.isFinite && $0.value >= 0 }) else { return nil }

        // Identity is not enough for deduplication: separate queries can
        // expose the same interval with different sample identifiers.
        let unique = Set(readings.map { Interval(start: $0.start, end: $0.end, meters: $0.value) })
        let sorted = unique.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.meters < $1.meters
        }

        var previousEnd: Date?
        var total = 0.0
        var result: [Point] = []
        for interval in sorted {
            guard interval.meters.isFinite, interval.meters >= 0,
                  interval.start >= workoutStart, interval.end <= workoutEnd,
                  interval.start < interval.end,
                  previousEnd.map({ interval.start >= $0 }) ?? true else {
                return nil
            }
            total += interval.meters
            guard total.isFinite else { return nil }
            result.append(Point(timestamp: interval.end, cumulativeMeters: total))
            previousEnd = interval.end
        }
        return result
    }

    private struct Interval: Hashable {
        let start: Date
        let end: Date
        let meters: Double
    }
}
