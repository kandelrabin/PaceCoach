import Combine
import HealthKit

enum WorkoutTarget {
    case pace(fasterSeconds: Double, slowerSeconds: Double)
    case heartRateZone(TargetHeartRateZone)
}

@MainActor
final class WorkoutManager: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private static let speedFreshnessTimeout: TimeInterval = 10
    private static let heartRateFreshnessTimeout: TimeInterval = 30

    @Published private(set) var currentPaceSecondsPerKilometer: Double?
    @Published private(set) var currentHeartRateBPM: Double?
    @Published private(set) var zoneCoachingState: ZoneDecisionEngine.CoachingState = .findingZone
    @Published private(set) var coachingState: PaceDecisionEngine.CoachingState = .findingPace
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?

    private let healthStore = HealthKitAuthorization.healthStore
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var endContinuation: CheckedContinuation<Void, Never>?
    private var isFinishingWorkout = false
    private var isEndingZoneWorkout = false
    private var latestSpeedSampleDate: Date?
    private var latestHeartRateSampleDate: Date?
    private var paceExpirationTask: Task<Void, Never>?
    private var heartRateExpirationTask: Task<Void, Never>?
    private var decisionEngine: PaceDecisionEngine?
    private var zoneDecisionEngine: ZoneDecisionEngine?
    let target: WorkoutTarget
    private let voiceCoaching = VoiceCoachingCoordinator()

    init(fasterPaceSeconds: Double, slowerPaceSeconds: Double) {
        target = .pace(fasterSeconds: fasterPaceSeconds, slowerSeconds: slowerPaceSeconds)
        decisionEngine = PaceDecisionEngine(
            fasterPaceSeconds: fasterPaceSeconds,
            slowerPaceSeconds: slowerPaceSeconds
        )
        super.init()
        // Keep Target Pace's previously eager audio readiness unchanged.
        voiceCoaching.prewarmAudio()
    }

    init(targetZone: TargetHeartRateZone) {
        target = .heartRateZone(targetZone)
        decisionEngine = nil
        zoneDecisionEngine = ZoneDecisionEngine(target: targetZone)
        super.init()
    }

    func startWorkout() async {
        guard !isStarting, workoutSession == nil else { return }

        resetWorkoutState()
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        guard HKHealthStore.isHealthDataAvailable(),
              HKObjectType.quantityType(forIdentifier: .runningSpeed) != nil else {
            errorMessage = "Health data is unavailable on this device."
            return
        }

        if case .heartRateZone = target {
            guard HKObjectType.quantityType(forIdentifier: .heartRate) != nil else {
                errorMessage = "Heart-rate data is unavailable on this device."
                return
            }
        }

        do {
            if case .heartRateZone = target {
                try await HealthKitAuthorization.ensureAuthorized(for: .targetZoneWorkout)
            } else {
                try await HealthKitAuthorization.ensureAuthorized(for: .targetPaceWorkout)
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .running
            configuration.locationType = .outdoor

            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            let dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            builder.dataSource = dataSource
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            workoutBuilder = builder

            let startDate = Date()
            session.startActivity(with: startDate)
            switch target {
            case .pace: voiceCoaching.startWorkout(mode: .pace)
            case .heartRateZone: voiceCoaching.startWorkout(mode: .zone)
            }
            try await builder.beginCollection(at: startDate)
        } catch {
            #if DEBUG
            if case .heartRateZone = target {
                TargetZoneWorkoutLog.write("startup failed: \(error)")
            }
            #endif
            resetWorkoutState()
            workoutBuilder?.discardWorkout()
            workoutSession?.end()
            workoutBuilder = nil
            workoutSession = nil
            errorMessage = error.localizedDescription
        }
    }

    func endWorkout() async {
        guard let workoutSession else { return }

        if case .heartRateZone = target {
            isEndingZoneWorkout = true
            clearCurrentHeartRate()
            zoneDecisionEngine?.resetWorkout()
        }
        voiceCoaching.endWorkout()
        await withCheckedContinuation { continuation in
            endContinuation = continuation
            workoutSession.stopActivity(with: Date())
        }
    }

    @objc nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .stopped else { return }

        Task { @MainActor [weak self] in
            await self?.finishWorkout(at: date)
        }
    }

    @objc nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.errorMessage = message
            self.voiceCoaching.endWorkout()
            if case .heartRateZone = self.target {
                self.isEndingZoneWorkout = true
                self.zoneDecisionEngine?.resetWorkout()
                #if DEBUG
                TargetZoneWorkoutLog.write("session failure: \(message)")
                #endif
            }
            self.clearCurrentHeartRate()
        }
    }

    @objc nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        if let runningSpeedType = HKObjectType.quantityType(forIdentifier: .runningSpeed),
           collectedTypes.contains(runningSpeedType),
           let statistics = workoutBuilder.statistics(for: runningSpeedType),
           let speedQuantity = statistics.mostRecentQuantity(),
           let sampleDate = statistics.mostRecentQuantityDateInterval()?.end {
            let speedInMetersPerSecond = speedQuantity.doubleValue(
                for: HKUnit.meter().unitDivided(by: HKUnit.second())
            )
            Task { @MainActor [weak self] in
                self?.receiveSpeed(speedInMetersPerSecond, sampleDate: sampleDate)
            }
        }

        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
           collectedTypes.contains(heartRateType) {
            let arrivalDate = Date()
            let statistics = workoutBuilder.statistics(for: heartRateType)
            let recentQuantity = statistics?.mostRecentQuantity()
            let recentInterval = statistics?.mostRecentQuantityDateInterval()
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            if let recentQuantity {
                let bpm = recentQuantity.doubleValue(for: bpmUnit)
                // The delegate reports newly collected HR data. If HealthKit
                // omits the optional most-recent interval, use this callback's
                // arrival time for display freshness, never a workout average.
                let sampleDate = recentInterval?.end ?? arrivalDate
                Task { @MainActor [weak self] in
                    self?.receiveHeartRate(
                        bpm,
                        sampleDate: sampleDate
                    )
                }
            }
        }
    }

    @objc nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }

    private func receiveSpeed(_ speedInMetersPerSecond: Double, sampleDate: Date) {
        guard case .pace = target else { return }
        guard latestSpeedSampleDate.map({ sampleDate > $0 }) ?? true else { return }
        latestSpeedSampleDate = sampleDate

        let sampleAge = Date().timeIntervalSince(sampleDate)
        guard speedInMetersPerSecond.isFinite,
              speedInMetersPerSecond > 0.5,
              sampleAge < Self.speedFreshnessTimeout else {
            clearCurrentPace()
            return
        }

        let paceSecondsPerKilometer = 1_000 / speedInMetersPerSecond
        currentPaceSecondsPerKilometer = paceSecondsPerKilometer
        guard let wasCoachingActive = decisionEngine?.isCoachingActive,
              let newState = decisionEngine?.addSample(
            paceSecondsPerKilometer: paceSecondsPerKilometer,
            at: sampleDate
        ) else { return }
        coachingState = newState
        voiceCoaching.update(coachingState, activatedNow: !wasCoachingActive && decisionEngine?.isCoachingActive == true)
        paceExpirationTask?.cancel()

        let remainingFreshness = max(0, Self.speedFreshnessTimeout - max(0, sampleAge))
        let sleepNanoseconds = UInt64(remainingFreshness * 1_000_000_000)
        paceExpirationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.latestSpeedSampleDate == sampleDate else { return }
            self.clearCurrentPace()
        }
    }

    private func receiveHeartRate(_ bpm: Double, sampleDate: Date) {
        guard case .heartRateZone = target else { return }
        guard workoutSession != nil, !isEndingZoneWorkout, !isFinishingWorkout else {
            return
        }
        guard latestHeartRateSampleDate.map({ sampleDate > $0 }) ?? true else {
            return
        }
        // A new callback can race the scheduled expiry after a long gap. Break
        // decision continuity even if that expiry task has not run yet.
        if let latestHeartRateSampleDate,
           sampleDate.timeIntervalSince(latestHeartRateSampleDate) >= Self.heartRateFreshnessTimeout {
            clearCurrentHeartRate()
        }
        latestHeartRateSampleDate = sampleDate

        let sampleAge = Date().timeIntervalSince(sampleDate)
        guard bpm.isFinite, bpm > 0 else {
            clearCurrentHeartRate()
            return
        }
        guard sampleAge < Self.heartRateFreshnessTimeout else {
            clearCurrentHeartRate()
            return
        }

        currentHeartRateBPM = bpm
        let wasCoachingActive = zoneDecisionEngine?.isCoachingActive ?? false
        zoneCoachingState = zoneDecisionEngine?.addSample(bpm: bpm, at: sampleDate) ?? .findingZone
        voiceCoaching.update(
            zoneCoachingState,
            activatedNow: !wasCoachingActive && zoneDecisionEngine?.isCoachingActive == true
        )
        heartRateExpirationTask?.cancel()
        let remainingFreshness = max(0, Self.heartRateFreshnessTimeout - max(0, sampleAge))
        heartRateExpirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remainingFreshness))
            guard !Task.isCancelled,
                  let self,
                  self.latestHeartRateSampleDate == sampleDate else { return }
            self.clearCurrentHeartRate()
        }
    }

    private func clearCurrentHeartRate() {
        heartRateExpirationTask?.cancel()
        heartRateExpirationTask = nil
        currentHeartRateBPM = nil
        zoneDecisionEngine?.heartRateUnavailable()
        zoneCoachingState = .findingZone
        voiceCoaching.heartRateUnavailable()
    }

    private func clearCurrentPace() {
        paceExpirationTask?.cancel()
        paceExpirationTask = nil
        currentPaceSecondsPerKilometer = nil
        decisionEngine?.clearTransientPace()
        coachingState = decisionEngine?.coachingState ?? .findingPace
        voiceCoaching.paceUnavailable()
    }

    private func resetWorkoutState() {
        if case .pace = target {
            clearCurrentPace()
            decisionEngine?.resetWorkout()
            coachingState = decisionEngine?.coachingState ?? .findingPace
            voiceCoaching.endWorkout()
        } else {
            clearCurrentHeartRate()
            zoneDecisionEngine?.resetWorkout()
            voiceCoaching.endWorkout()
        }
        latestSpeedSampleDate = nil
        latestHeartRateSampleDate = nil
        isEndingZoneWorkout = false
    }

    private func finishWorkout(at endDate: Date) async {
        guard !isFinishingWorkout else { return }
        isFinishingWorkout = true
        voiceCoaching.endWorkout()

        if let workoutBuilder, let workoutSession {
            do {
                try await workoutBuilder.endCollection(at: endDate)
                _ = try await workoutBuilder.finishWorkout()
            } catch {
                errorMessage = error.localizedDescription
                #if DEBUG
                if case .heartRateZone = target {
                    TargetZoneWorkoutLog.write("workout finish failed: \(error)")
                }
                #endif
            }
            workoutSession.end()
        }

        workoutBuilder = nil
        workoutSession = nil
        resetWorkoutState()
        isFinishingWorkout = false
        endContinuation?.resume()
        endContinuation = nil
    }
}

#if DEBUG
private enum TargetZoneWorkoutLog {
    static func write(_ message: String) {
        print("[TargetZoneWorkout] \(message)")
    }
}
#endif
