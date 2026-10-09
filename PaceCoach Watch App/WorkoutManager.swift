import Combine
import HealthKit

@MainActor
final class WorkoutManager: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    @Published private(set) var currentPaceSecondsPerKilometer: Double?
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var endContinuation: CheckedContinuation<Void, Never>?
    private var isFinishingWorkout = false

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
              let speedQuantity = workoutBuilder.statistics(for: runningSpeedType)?.mostRecentQuantity() else {
            return
        }

        let speedInMetersPerSecond = speedQuantity.doubleValue(
            for: HKUnit.meter().unitDivided(by: HKUnit.second())
        )
        guard speedInMetersPerSecond > 0 else { return }

        let paceSecondsPerKilometer = 1_000 / speedInMetersPerSecond
        Task { @MainActor [weak self] in
            self?.currentPaceSecondsPerKilometer = paceSecondsPerKilometer
        }
    }

    @objc nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }

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
        currentPaceSecondsPerKilometer = nil
        isFinishingWorkout = false
        endContinuation?.resume()
        endContinuation = nil
    }
}
