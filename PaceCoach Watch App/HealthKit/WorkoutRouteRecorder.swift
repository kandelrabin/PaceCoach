import CoreLocation
import HealthKit

/// Captures locations for one live workout, then saves the standalone route
/// against the already saved HKWorkout.
@MainActor
final class WorkoutRouteRecorder: NSObject, CLLocationManagerDelegate {
    /// Only the system boundaries are injected; filtering, insertion ordering,
    /// draining, and finalization still run in this recorder in deterministic checks.
    struct LocationClient {
        let authorizationStatus: @MainActor () -> CLAuthorizationStatus
        let servicesEnabled: @MainActor () -> Bool
        let requestAuthorization: @MainActor () -> Void
        let startUpdatingLocation: @MainActor () -> Void
        let stopUpdatingLocation: @MainActor () -> Void
        let clearDelegate: @MainActor () -> Void
    }

    struct RouteClient {
        let insertRouteData: @MainActor ([CLLocation]) async throws -> Void
        let finishRoute: @MainActor (HKWorkout) async throws -> Void
    }

    private final class DrainSignal {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func complete(_ drained: Bool) {
            continuation?.resume(returning: drained)
            continuation = nil
        }
    }

    private struct LocationKey: Hashable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double

        init(_ location: CLLocation) {
            timestamp = location.timestamp
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
        }
    }

    private let locationClient: LocationClient
    private let routeClient: RouteClient
    private let startDate: Date
    private var endDate: Date?
    private var started = false
    private var capturing = false
    private var seenLocations = Set<LocationKey>()
    private var insertionTail: Task<Void, Never>?
    private var insertionError: Error?
    private var insertionAbandoned = false
    private var drainTask: Task<Void, Never>?
    private var insertedLocationCount = 0
    private var didFinishRoute = false
    private var receivedLocationCount = 0
    private var captureStarted = false
    private var authorizationAtStart: Int32?
    private var servicesAtStart: Bool?
    private var lastLocationError: String?
    private var drainDuration: TimeInterval?

    enum RouteResult: CustomStringConvertible {
        case saved(accepted: Int, inserted: Int)
        case failed(reason: String, accepted: Int, inserted: Int)

        var description: String {
            switch self {
            case .saved(let accepted, let inserted):
                "saved; accepted=\(accepted), inserted=\(inserted)"
            case .failed(let reason, let accepted, let inserted):
                "not saved (\(reason)); accepted=\(accepted), inserted=\(inserted)"
            }
        }
    }

    convenience init(routeBuilder: HKWorkoutRouteBuilder, startDate: Date) {
        let manager = CLLocationManager()
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true
        self.init(
            locationClient: LocationClient(
                authorizationStatus: { manager.authorizationStatus },
                servicesEnabled: { CLLocationManager.locationServicesEnabled() },
                requestAuthorization: { manager.requestWhenInUseAuthorization() },
                startUpdatingLocation: { manager.startUpdatingLocation() },
                stopUpdatingLocation: { manager.stopUpdatingLocation() },
                clearDelegate: { manager.delegate = nil }
            ),
            routeClient: RouteClient(
                insertRouteData: { try await routeBuilder.insertRouteData($0) },
                finishRoute: { workout in
                    let _: HKWorkoutRoute = try await routeBuilder.finishRoute(with: workout, metadata: nil)
                }
            ),
            startDate: startDate
        )
        manager.delegate = self
    }

    init(locationClient: LocationClient, routeClient: RouteClient, startDate: Date) {
        self.locationClient = locationClient
        self.routeClient = routeClient
        self.startDate = startDate
        super.init()
    }

    func start() {
        guard !started, endDate == nil else { return }
        started = true
        authorizationAtStart = locationClient.authorizationStatus().rawValue
        servicesAtStart = locationClient.servicesEnabled()
        guard locationClient.servicesEnabled() else {
            return
        }
        switch locationClient.authorizationStatus() {
        case .authorizedWhenInUse, .authorizedAlways:
            startCapture()
        case .notDetermined:
            locationClient.requestAuthorization()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    /// Idempotent: normal End Run and an external HealthKit stop may race.
    func stopAndDrain(at date: Date) async {
        if let drainTask {
            await drainTask.value
            return
        }
        endDate = date
        locationClient.stopUpdatingLocation()
        locationClient.clearDelegate()
        capturing = false
        drainTask = Task { [self] in
            let drainStart = Date()
            defer { drainDuration = Date().timeIntervalSince(drainStart) }
            if let insertionTail {
                // A stalled route insert cannot hold the HealthKit workout save.
                let drained = await withCheckedContinuation { continuation in
                    let signal = DrainSignal(continuation)
                    Task {
                        await insertionTail.value
                        signal.complete(true)
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(8))
                        signal.complete(false)
                    }
                }
                if !drained {
                    insertionAbandoned = true
                }
            }
        }
        await drainTask?.value
    }

    func diagnosticSummary(result: String) -> String {
        let insertFailure = insertionError.map(Self.errorSummary) ?? "none"
        let duration = drainDuration.map { String(format: "%.2fs", $0) } ?? "not drained"
        return [
            result,
            "received=\(receivedLocationCount), accepted=\(seenLocations.count), inserted=\(insertedLocationCount)",
            "captureStarted=\(captureStarted)",
            "locationAuth=\(authorizationAtStart.map(String.init) ?? "unknown")→\(locationClient.authorizationStatus().rawValue)",
            "services=\(servicesAtStart.map(String.init) ?? "unknown")→\(locationClient.servicesEnabled())",
            "drain=\(duration), timedOut=\(insertionAbandoned)",
            "locationError=\(lastLocationError ?? "none"), insertError=\(insertFailure)"
        ].joined(separator: "; ")
    }

    private static func errorSummary(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) code \(error.code)"
    }

    /// The SDK requires a saved workout for a standalone route builder.
    /// Route errors never invalidate or delete that workout.
    func finishRoute(with workout: HKWorkout) async -> RouteResult {
        let accepted = seenLocations.count
        guard endDate != nil, !didFinishRoute else {
            return .failed(reason: "invalid finalization state", accepted: accepted,
                           inserted: insertedLocationCount)
        }
        didFinishRoute = true
        await drainTask?.value
        guard !insertionAbandoned else {
            return .failed(reason: "route insert timed out", accepted: accepted,
                           inserted: insertedLocationCount)
        }
        guard insertedLocationCount > 0 else {
            let reason = insertionError == nil
                ? "no accepted GPS points; location authorization \(locationClient.authorizationStatus().rawValue), services \(locationClient.servicesEnabled())"
                : "route insert failed"
            return .failed(reason: reason,
                           accepted: accepted, inserted: 0)
        }
        do {
            try await routeClient.finishRoute(workout)
            return .saved(accepted: accepted, inserted: insertedLocationCount)
        } catch {
            let failure = error as NSError
            return .failed(reason: "HealthKit \(failure.domain) code \(failure.code)",
                           accepted: accepted, inserted: insertedLocationCount)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.authorizationDidChange(to: manager.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            self?.accept(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.receiveLocationError(error)
        }
    }

    // Actor-isolated event handlers shared by the delegates and deterministic checks.
    func authorizationDidChange(to status: CLAuthorizationStatus) {
        guard started, endDate == nil else { return }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            startCapture()
        default:
            break
        }
    }

    static func coreLocationErrorCode(_ error: Error) -> CLError.Code? {
        let error = error as NSError
        guard error.domain == kCLErrorDomain else { return nil }
        return CLError.Code(rawValue: error.code)
    }

    func receiveLocationError(_ error: Error) {
        guard endDate == nil else { return }
        lastLocationError = Self.errorSummary(error)
        // locationUnknown is transient: the existing continuous service keeps
        // trying. Only denied requires stopping it; other errors are diagnostic.
        guard Self.coreLocationErrorCode(error) == .denied else { return }
        locationClient.stopUpdatingLocation()
        capturing = false
    }

    private func startCapture() {
        guard started, endDate == nil, !capturing else { return }
        capturing = true
        captureStarted = true
        locationClient.startUpdatingLocation()
    }

    func accept(_ locations: [CLLocation]) {
        receivedLocationCount += locations.count
        guard started, endDate == nil, insertionError == nil else { return }
        let futureLimit = Date().addingTimeInterval(10)
        var batch: [CLLocation] = []
        for location in locations {
            let coordinate = location.coordinate
            let accuracy = location.horizontalAccuracy
            guard CLLocationCoordinate2DIsValid(coordinate),
                  coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                  accuracy.isFinite, accuracy >= 0, accuracy <= 50,
                  location.timestamp >= startDate, location.timestamp <= futureLimit else { continue }
            guard seenLocations.insert(LocationKey(location)).inserted else { continue }
            batch.append(location)
        }
        guard !batch.isEmpty else { return }
        let previous = insertionTail
        insertionTail = Task { [self] in
            await previous?.value
            guard insertionError == nil, !insertionAbandoned else { return }
            do {
                try await routeClient.insertRouteData(batch)
                insertedLocationCount += batch.count
            } catch {
                insertionError = error
                locationClient.stopUpdatingLocation()
                capturing = false
            }
        }
    }
}
