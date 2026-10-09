import Combine
import HealthKit

@MainActor
final class WorkoutManager: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private static let speedFreshnessTimeout: TimeInterval = 10

    @Published private(set) var currentPaceSecondsPerKilometer: Double?
    @Published private(set) var coachingDecision: PaceDecisionEngine.Decision?
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var endContinuation: CheckedContinuation<Void, Never>?
    private var isFinishingWorkout = false
    private var latestSpeedSampleDate: Date?
    private var paceExpirationTask: Task<Void, Never>?
    private var decisionEngine: PaceDecisionEngine

    init(fasterPaceSeconds: Double, slowerPaceSeconds: Double) {
        decisionEngine = PaceDecisionEngine(
            fasterPaceSeconds: fasterPaceSeconds,
            slowerPaceSeconds: slowerPaceSeconds
        )
        super.init()
    }

    func startWorkout() async {
        guard !isStarting, workoutSession == nil else { return }

        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        guard HKHealthStore.isHealthDataAvailable(),
              let runningSpeedType = HKObjectType.quantityType(forIdentifier: .runningSpeed) else {
            errorMessage = "Health data is unavailable on this device."
            return
        }

        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [runningSpeedType]
            )

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .running
            configuration.locationType = .outdoor

            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            workoutBuilder = builder

            let startDate = Date()
            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)
        } catch {
            workoutBuilder?.discardWorkout()
            workoutSession?.end()
            workoutBuilder = nil
            workoutSession = nil
            errorMessage = error.localizedDescription
        }
    }

    func endWorkout() async {
        guard let workoutSession else { return }

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
            self?.errorMessage = message
        }
    }

    @objc nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let runningSpeedType = HKObjectType.quantityType(forIdentifier: .runningSpeed),
              collectedTypes.contains(runningSpeedType),
              let statistics = workoutBuilder.statistics(for: runningSpeedType),
              let speedQuantity = statistics.mostRecentQuantity(),
              let sampleDate = statistics.mostRecentQuantityDateInterval()?.end else {
            return
        }

        let speedInMetersPerSecond = speedQuantity.doubleValue(
            for: HKUnit.meter().unitDivided(by: HKUnit.second())
        )
        Task { @MainActor [weak self] in
            self?.receiveSpeed(speedInMetersPerSecond, sampleDate: sampleDate)
        }
    }

    @objc nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }

    private func receiveSpeed(_ speedInMetersPerSecond: Double, sampleDate: Date) {
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
        coachingDecision = decisionEngine.addSample(
            paceSecondsPerKilometer: paceSecondsPerKilometer,
            at: sampleDate
        )
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

    private func clearCurrentPace() {
        paceExpirationTask?.cancel()
        paceExpirationTask = nil
        currentPaceSecondsPerKilometer = nil
        decisionEngine.reset()
        coachingDecision = nil
    }

    private func finishWorkout(at endDate: Date) async {
        guard !isFinishingWorkout else { return }
        isFinishingWorkout = true

        if let workoutBuilder, let workoutSession {
            do {
                try await workoutBuilder.endCollection(at: endDate)
                _ = try await workoutBuilder.finishWorkout()
            } catch {
                errorMessage = error.localizedDescription
            }
            workoutSession.end()
        }

        workoutBuilder = nil
        workoutSession = nil
        clearCurrentPace()
        latestSpeedSampleDate = nil
        isFinishingWorkout = false
        endContinuation?.resume()
        endContinuation = nil
    }
}
