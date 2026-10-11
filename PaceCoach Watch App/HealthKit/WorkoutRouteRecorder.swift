import CoreLocation
import HealthKit

/// Captures the locations for one live workout. The route builder belongs to
/// the workout builder, so finishing the workout also finishes its route.
@MainActor
final class WorkoutRouteRecorder: NSObject, CLLocationManagerDelegate {
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

    private let manager = CLLocationManager()
    private let routeBuilder: HKWorkoutRouteBuilder
    private let startDate: Date
    private var endDate: Date?
    private var started = false
    private var capturing = false
    private var seenLocations = Set<LocationKey>()
    private var insertionTail: Task<Void, Never>?
    private var insertionError: Error?
    private var insertionAbandoned = false
    private var drainTask: Task<Void, Never>?

    init(routeBuilder: HKWorkoutRouteBuilder, startDate: Date) {
        self.routeBuilder = routeBuilder
        self.startDate = startDate
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true
    }

    func start() {
        guard !started, endDate == nil else { return }
        started = true
        guard CLLocationManager.locationServicesEnabled() else {
            return
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            startCapture()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
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
        manager.stopUpdatingLocation()
        manager.delegate = nil
        capturing = false
        drainTask = Task { [self] in
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.started, self.endDate == nil else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.startCapture()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            self?.accept(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.endDate == nil else { return }
            self.manager.stopUpdatingLocation()
            self.capturing = false
        }
    }

    private func startCapture() {
        guard started, endDate == nil, !capturing else { return }
        capturing = true
        manager.startUpdatingLocation()
    }

    private func accept(_ locations: [CLLocation]) {
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
                try await routeBuilder.insertRouteData(batch)
            } catch {
                insertionError = error
                manager.stopUpdatingLocation()
                capturing = false
            }
        }
    }
}
