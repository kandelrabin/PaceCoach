import Foundation

enum HeartRateProfileCalculator {
    struct RestingSample {
        let date: Date
        let bpm: Double
    }

    struct RestingEstimate {
        let bpm: Double
        let dayCount: Int
        let sampleCount: Int

        var isSparse: Bool { dayCount < 3 }
    }

    struct WorkoutReading {
        let start: Date
        let end: Date
        let bpm: Double
        let isFromSeries: Bool
    }

    enum PeakEvidence {
        case threeReadings
        case continuousSeries
    }

    struct CrediblePeak {
        let bpm: Double
        let start: Date
        let end: Date
        let supportingReadings: Int
        let lowestSupportingBPM: Double
        let highestSupportingBPM: Double
        let evidence: PeakEvidence

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    static func representativeRestingHR(
        from samples: [RestingSample],
        calendar: Calendar = .current
    ) -> RestingEstimate? {
        let validSamples = samples.filter { $0.bpm.isFinite && $0.bpm > 0 }
        var latestByDay: [Date: RestingSample] = [:]
        for sample in validSamples {
            let day = calendar.startOfDay(for: sample.date)
            if let previous = latestByDay[day], previous.date >= sample.date { continue }
            latestByDay[day] = sample
        }

        let values = latestByDay.values.map(\.bpm).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        let median = values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
        return RestingEstimate(bpm: median, dayCount: values.count, sampleCount: validSamples.count)
    }

    static func crediblePeak(in workoutReadings: [WorkoutReading]) -> CrediblePeak? {
        let readings = workoutReadings
            .filter { $0.bpm.isFinite && $0.bpm > 0 && $0.end >= $0.start }
            .sorted { $0.start < $1.start }
        var best: CrediblePeak?

        // A candidate needs three distinct readings within 30 seconds, spanning
        // at least 10 seconds, with a total HR spread of at most 5 BPM. Use the
        // middle HR of those three, so one high optical spike cannot set the peak.
        for first in readings.indices {
            for second in (first + 1)..<readings.count {
                let firstToSecond = readings[second].start.timeIntervalSince(readings[first].start)
                if firstToSecond > 30 { break }
                if firstToSecond <= 0 { continue }

                for third in (second + 1)..<readings.count {
                    let span = readings[third].start.timeIntervalSince(readings[first].start)
                    if span > 30 { break }
                    if span < 10 || readings[third].start <= readings[second].start { continue }

                    let values = [readings[first].bpm, readings[second].bpm, readings[third].bpm].sorted()
                    guard values[2] - values[0] <= 5 else { continue }
                    let candidate = CrediblePeak(
                        bpm: values[1],
                        start: readings[first].start,
                        end: readings[third].start,
                        supportingReadings: 3,
                        lowestSupportingBPM: values[0],
                        highestSupportingBPM: values[2],
                        evidence: .threeReadings
                    )
                    if isStronger(candidate, than: best) { best = candidate }
                }
            }
        }

        // HealthKit may coalesce repeated equal HR values into one continuous
        // interval inside a condensed series. An interval of at least 20 seconds
        // is sustained evidence, unlike a single instantaneous sample.
        for reading in readings where reading.isFromSeries && reading.end.timeIntervalSince(reading.start) >= 20 {
            let candidate = CrediblePeak(
                bpm: reading.bpm,
                start: reading.start,
                end: reading.end,
                supportingReadings: 1,
                lowestSupportingBPM: reading.bpm,
                highestSupportingBPM: reading.bpm,
                evidence: .continuousSeries
            )
            if isStronger(candidate, than: best) { best = candidate }
        }

        return best
    }

    private static func isStronger(_ candidate: CrediblePeak, than current: CrediblePeak?) -> Bool {
        guard let current else { return true }
        if candidate.bpm != current.bpm { return candidate.bpm > current.bpm }
        if candidate.duration != current.duration { return candidate.duration > current.duration }
        return candidate.end > current.end
    }
}
