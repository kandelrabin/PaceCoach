import Foundation
import HealthKit

struct HeartRateProfile {
    enum QueryStatus {
        case loaded
        case noData
        case error(String)
        case notRun(String)
    }

    struct RestingReading {
        let id: UUID
        let date: Date
        let bpm: Double
    }

    struct RunningWorkout {
        let id: UUID
        let date: Date
        let source: String
        let heartRateSampleObjects: Int
        let heartRateSeriesObjects: Int
        let storedHeartRateQuantities: Int
        let highestObservedBPM: Double?
        let crediblePeak: HeartRateProfileCalculator.CrediblePeak?
    }

    struct EstimatedMaxHR {
        let bpm: Double
        let workoutDate: Date
        let workoutSource: String
        let peak: HeartRateProfileCalculator.CrediblePeak
    }

    let restingReadings: [RestingReading]
    let runningWorkouts: [RunningWorkout]
    let restingStatus: QueryStatus
    let runningWorkoutStatus: QueryStatus
    let workoutHeartRateStatus: QueryStatus
    let workoutHeartRateQueryIssues: Int

    var representativeRestingHR: HeartRateProfileCalculator.RestingEstimate? {
        HeartRateProfileCalculator.representativeRestingHR(
            from: restingReadings.map { .init(date: $0.date, bpm: $0.bpm) }
        )
    }

    var estimatedMaxHR: EstimatedMaxHR? {
        runningWorkouts.compactMap { workout -> EstimatedMaxHR? in
            guard let peak = workout.crediblePeak else { return nil }
            return .init(
                bpm: peak.bpm,
                workoutDate: workout.date,
                workoutSource: workout.source,
                peak: peak
            )
        }.max { left, right in
            left.bpm == right.bpm
                ? left.workoutDate < right.workoutDate
                : left.bpm < right.bpm
        }
    }

    var highestObservedWorkoutBPM: Double? {
        runningWorkouts.compactMap(\.highestObservedBPM).max()
    }

    var workoutsWithHeartRate: Int {
        runningWorkouts.filter { $0.heartRateSampleObjects > 0 }.count
    }

    var heartRateSampleObjects: Int {
        runningWorkouts.reduce(0) { $0 + $1.heartRateSampleObjects }
    }

    var heartRateSeriesObjects: Int {
        runningWorkouts.reduce(0) { $0 + $1.heartRateSeriesObjects }
    }

    var storedHeartRateQuantities: Int {
        runningWorkouts.reduce(0) { $0 + $1.storedHeartRateQuantities }
    }
}

final class HeartRateProfileService {
    static let workoutHistoryDays = 90
    static let restingHistoryDays = 30

    private let healthStore = HKHealthStore()
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    func load() async throws -> HeartRateProfile {
        guard HKHealthStore.isHealthDataAvailable(),
              let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let restingHeartRateType = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else {
            return unavailableProfile("Health data is unavailable on this device.")
        }

        do {
            try await healthStore.requestAuthorization(
                toShare: [],
                read: [heartRateType, restingHeartRateType, HKObjectType.workoutType()]
            )
        } catch {
            logQueryError("HealthKit authorization", error: error)
            return unavailableProfile("HealthKit authorization failed: \(error.localizedDescription)")
        }

        let now = Date()
        let restingStart = now.addingTimeInterval(-TimeInterval(Self.restingHistoryDays * 24 * 60 * 60))
        let workoutStart = now.addingTimeInterval(-TimeInterval(Self.workoutHistoryDays * 24 * 60 * 60))
        let newestFirst = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]

        let restingPredicate = HKQuery.predicateForSamples(
            withStart: restingStart, end: now, options: .strictStartDate
        )
        var restingReadings: [HeartRateProfile.RestingReading] = []
        var restingStatus: HeartRateProfile.QueryStatus = .noData
        do {
            let restingSamples = try await samples(
                of: restingHeartRateType,
                matching: restingPredicate,
                limit: HKObjectQueryNoLimit,
                sortedBy: newestFirst
            )
            log("Resting-HR samples returned: \(restingSamples.count)")
            restingReadings = restingSamples.compactMap { sample -> HeartRateProfile.RestingReading? in
                guard let sample = sample as? HKQuantitySample else { return nil }
                return .init(id: sample.uuid, date: sample.endDate, bpm: sample.quantity.doubleValue(for: bpmUnit))
            }
            restingStatus = restingReadings.isEmpty ? .noData : .loaded
        } catch {
            log("Resting-HR samples returned: 0 (query failed)")
            logQueryError("resting HR HKSampleQuery", error: error)
            restingStatus = queryStatus(for: error)
        }

        try Task.checkCancellation()

        let runningPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .running),
            HKQuery.predicateForSamples(withStart: workoutStart, end: now, options: .strictStartDate)
        ])
        let workoutSamples: [HKSample]
        do {
            workoutSamples = try await samples(
                of: HKObjectType.workoutType(),
                matching: runningPredicate,
                limit: HKObjectQueryNoLimit,
                sortedBy: newestFirst
            )
        } catch {
            log("Running workouts returned: 0 (query failed)")
            logQueryError("running workout HKSampleQuery", error: error)
            log("Workouts with associated HR: 0 (workout query failed)")
            return HeartRateProfile(
                restingReadings: restingReadings,
                runningWorkouts: [],
                restingStatus: restingStatus,
                runningWorkoutStatus: queryStatus(for: error),
                workoutHeartRateStatus: isNoData(error) ? .noData : .notRun("Running workout query did not load"),
                workoutHeartRateQueryIssues: 0
            )
        }

        let workouts = workoutSamples.compactMap { $0 as? HKWorkout }
        log("Running workouts returned: \(workouts.count)")
        if let newest = workouts.map(\.startDate).max(),
           let oldest = workouts.map(\.startDate).min() {
            let formatter = ISO8601DateFormatter()
            log("Running workout dates: newest \(formatter.string(from: newest)); oldest \(formatter.string(from: oldest))")
        }

        var runningWorkouts: [HeartRateProfile.RunningWorkout] = []
        var workoutHeartRateQueryIssues = 0
        var firstHeartRateError: String?
        for workout in workouts {
            try Task.checkCancellation()
            let associatedPredicate = HKQuery.predicateForObjects(from: workout)
            var quantitySamples: [HKQuantitySample] = []
            var highestBPM: Double?
            var crediblePeak: HeartRateProfileCalculator.CrediblePeak?
            do {
                let heartRateSamples = try await samples(
                    of: heartRateType,
                    matching: associatedPredicate,
                    limit: HKObjectQueryNoLimit,
                    sortedBy: nil
                )
                quantitySamples = heartRateSamples.compactMap { $0 as? HKQuantitySample }

                // An empty workout must not trigger a statistics query with no input.
                if !quantitySamples.isEmpty {
                    var readings: [HeartRateProfileCalculator.WorkoutReading] = []
                    var seriesReadFailed = false
                    for sample in quantitySamples {
                        try Task.checkCancellation()
                        if sample.count > 1 {
                            do {
                                let seriesReadings = try await expandedReadings(in: sample, of: heartRateType)
                                guard !seriesReadings.isEmpty else { throw SeriesReadError.empty }
                                readings.append(contentsOf: seriesReadings)
                            } catch {
                                seriesReadFailed = true
                                workoutHeartRateQueryIssues += 1
                                firstHeartRateError = firstHeartRateError ?? error.localizedDescription
                                logQueryError("workout HR HKQuantitySeriesSampleQuery, sample \(sample.uuid)", error: error)
                            }
                        } else {
                            readings.append(.init(
                                start: sample.startDate,
                                end: sample.endDate,
                                bpm: sample.quantity.doubleValue(for: bpmUnit),
                                isFromSeries: false
                            ))
                        }
                    }
                    if !seriesReadFailed {
                        crediblePeak = HeartRateProfileCalculator.crediblePeak(in: readings)
                    }

                    do {
                        highestBPM = try await highestHeartRate(
                            of: heartRateType,
                            matching: associatedPredicate
                        )
                    } catch {
                        workoutHeartRateQueryIssues += 1
                        firstHeartRateError = firstHeartRateError ?? error.localizedDescription
                        logQueryError("workout HR HKStatisticsQuery(.discreteMax), workout \(workout.uuid)", error: error)
                    }
                }
            } catch {
                if !isNoData(error) {
                    workoutHeartRateQueryIssues += 1
                    firstHeartRateError = firstHeartRateError ?? error.localizedDescription
                }
                logQueryError("associated workout HR HKSampleQuery, workout \(workout.uuid)", error: error)
            }

            try Task.checkCancellation()

            runningWorkouts.append(.init(
                id: workout.uuid,
                date: workout.startDate,
                source: workout.sourceRevision.source.name,
                heartRateSampleObjects: quantitySamples.count,
                heartRateSeriesObjects: quantitySamples.filter { $0.count > 1 }.count,
                storedHeartRateQuantities: quantitySamples.reduce(0) { $0 + $1.count },
                highestObservedBPM: highestBPM,
                crediblePeak: crediblePeak
            ))
        }

        let workoutsWithHeartRate = runningWorkouts.filter { $0.heartRateSampleObjects > 0 }.count
        log("Workouts with associated HR: \(workoutsWithHeartRate)")
        let workoutHeartRateStatus: HeartRateProfile.QueryStatus
        if workoutsWithHeartRate > 0 {
            workoutHeartRateStatus = .loaded
        } else if let firstHeartRateError {
            workoutHeartRateStatus = .error(firstHeartRateError)
        } else {
            workoutHeartRateStatus = .noData
        }

        return HeartRateProfile(
            restingReadings: restingReadings,
            runningWorkouts: runningWorkouts,
            restingStatus: restingStatus,
            runningWorkoutStatus: workouts.isEmpty ? .noData : .loaded,
            workoutHeartRateStatus: workoutHeartRateStatus,
            workoutHeartRateQueryIssues: workoutHeartRateQueryIssues
        )
    }

    private func samples(
        of type: HKSampleType,
        matching predicate: NSPredicate,
        limit: Int,
        sortedBy sortDescriptors: [NSSortDescriptor]?
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private func highestHeartRate(
        of heartRateType: HKQuantityType,
        matching predicate: NSPredicate
    ) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: heartRateType,
                quantitySamplePredicate: predicate,
                options: .discreteMax
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: statistics?.maximumQuantity()?.doubleValue(for: self.bpmUnit))
                }
            }
            healthStore.execute(query)
        }
    }

    private func expandedReadings(
        in sample: HKQuantitySample,
        of heartRateType: HKQuantityType
    ) async throws -> [HeartRateProfileCalculator.WorkoutReading] {
        try await withCheckedThrowingContinuation { continuation in
            let accumulator = SeriesAccumulator(continuation: continuation)
            let predicate = HKQuery.predicateForObject(with: sample.uuid)
            let query = HKQuantitySeriesSampleQuery(
                quantityType: heartRateType,
                predicate: predicate
            ) { _, quantity, dateInterval, _, done, error in
                accumulator.receive(
                    bpm: quantity?.doubleValue(for: self.bpmUnit),
                    interval: dateInterval,
                    done: done,
                    error: error
                )
            }
            healthStore.execute(query)
        }
    }

    private final class SeriesAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: CheckedContinuation<[HeartRateProfileCalculator.WorkoutReading], Error>
        private var readings: [HeartRateProfileCalculator.WorkoutReading] = []
        private var completed = false

        init(continuation: CheckedContinuation<[HeartRateProfileCalculator.WorkoutReading], Error>) {
            self.continuation = continuation
        }

        func receive(bpm: Double?, interval: DateInterval?, done: Bool, error: Error?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            if let error {
                completed = true
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            if let bpm, let interval {
                readings.append(.init(
                    start: interval.start,
                    end: interval.end,
                    bpm: bpm,
                    isFromSeries: true
                ))
            }
            if done {
                completed = true
                let result = readings
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                lock.unlock()
            }
        }
    }

    private enum SeriesReadError: LocalizedError {
        case empty

        var errorDescription: String? { "Condensed HR series returned no readings." }
    }

    private func unavailableProfile(_ message: String) -> HeartRateProfile {
        HeartRateProfile(
            restingReadings: [],
            runningWorkouts: [],
            restingStatus: .error(message),
            runningWorkoutStatus: .error(message),
            workoutHeartRateStatus: .notRun(message),
            workoutHeartRateQueryIssues: 0
        )
    }

    private func queryStatus(for error: Error) -> HeartRateProfile.QueryStatus {
        isNoData(error) ? .noData : .error(error.localizedDescription)
    }

    private func isNoData(_ error: Error) -> Bool {
        let healthKitError = error as NSError
        return healthKitError.domain == HKErrorDomain
            && healthKitError.code == HKError.Code.errorNoData.rawValue
    }

    private func logQueryError(_ query: String, error: Error) {
        let details = error as NSError
        log("\(query) returned \(details.domain) code \(details.code): \(details.localizedDescription)")
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[HeartRateProfile] \(message)")
        #endif
    }
}
