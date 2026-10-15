import CoreLocation
import Foundation
import HealthKit

// Compile with WorkoutRouteRecorder.swift. Exercises the production recorder's
// actor-isolated delegate handlers with injected system operations. No location
// manager, Health database, GPS permission, or network is used.
@main
@MainActor
struct WorkoutRouteRecorderChecks {
    private static var checks = 0
    // watchOS's authorizedWhenInUse raw value; macOS marks its named case
    // unavailable, but these injected checks never query the host's permissions.
    private static let whenInUse = CLAuthorizationStatus(rawValue: 4)!

    static func main() async {
        await recoveryAfterPoint()
        await recoveryBeforeFirstFixAndRepeatedErrors()
        await errorClassification()
        await denialAndIndependentWorkoutSave()
        await callbacksAfterEnd()
        await authorizationAndUnavailableServices()
        await filtering()
        await serializedInsertsAndConcurrentStop()
        await insertionFailureSalvagesEarlierPoints()
        await finalizationGuardsAndFailure()
        print("Workout route recorder checks passed (\(checks) assertions)")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    private static func error(_ code: CLError.Code) -> NSError {
        NSError(domain: kCLErrorDomain, code: code.rawValue)
    }

    private static func saved(_ result: WorkoutRouteRecorder.RouteResult,
                              accepted: Int, inserted: Int) {
        guard case .saved(let actualAccepted, let actualInserted) = result else {
            preconditionFailure("Expected saved route, got \(result)")
        }
        check(actualAccepted == accepted && actualInserted == inserted, "saved counts")
    }

    private static func failed(_ result: WorkoutRouteRecorder.RouteResult,
                               containing reason: String, accepted: Int, inserted: Int) {
        guard case .failed(let actualReason, let actualAccepted, let actualInserted) = result else {
            preconditionFailure("Expected failed route, got \(result)")
        }
        check(actualReason.contains(reason), "route failure reason")
        check(actualAccepted == accepted && actualInserted == inserted, "failed counts")
    }

    private static func recoveryAfterPoint() async {
        let f = Fixture()
        let recorder = f.recorder()
        recorder.start()
        recorder.accept([f.point(1)])
        await f.firstInsertStarted.wait()
        recorder.receiveLocationError(error(.locationUnknown))
        check(f.stops == 0 && f.starts == 1, "transient error neither stops nor restarts service")
        recorder.authorizationDidChange(to: .authorizedAlways)
        check(f.starts == 1, "transient error keeps capturing true")
        recorder.accept([f.point(2), f.point(3)])
        await recorder.stopAndDrain(at: Date())
        saved(await recorder.finishRoute(with: f.workout), accepted: 3, inserted: 3)
        check(f.inserted.map(\.timestamp) == [f.point(1), f.point(2), f.point(3)].map(\.timestamp),
              "real later locations reach route writer")
        check(f.finishedWorkouts == [f.workout.uuid], "route attaches to supplied saved workout")
        check(f.stops == 1 && f.delegateClears == 1, "only normal end stops collection")
        let diagnostic = recorder.diagnosticSummary(result: "saved")
        check(diagnostic.contains("received=3, accepted=3, inserted=3"), "recovered diagnostic counts")
        check(diagnostic.contains("locationError=kCLErrorDomain code 0"), "historical transient error preserved")
        check(diagnostic.contains("timedOut=false") && diagnostic.contains("insertError=none"),
              "normal drain and insertion diagnostics")
    }

    private static func recoveryBeforeFirstFixAndRepeatedErrors() async {
        let f = Fixture()
        let recorder = f.recorder()
        recorder.start()
        for _ in 0..<3 { recorder.receiveLocationError(error(.locationUnknown)) }
        check(f.stops == 0 && f.starts == 1, "repeated errors before first fix leave service active")
        check(recorder.diagnosticSummary(result: "capturing").contains("received=0, accepted=0, inserted=0"),
              "transient error does not synthesize points")
        recorder.accept([f.point(1)])
        recorder.receiveLocationError(error(.locationUnknown))
        recorder.accept([f.point(2)])
        check(f.stops == 0 && f.starts == 1, "repeated errors after fix leave service active")
        await recorder.stopAndDrain(at: Date())
        saved(await recorder.finishRoute(with: f.workout), accepted: 2, inserted: 2)
    }

    private static func errorClassification() async {
        let typedUnknown = CLError(_nsError: error(.locationUnknown))
        let typedDenied = CLError(_nsError: error(.denied))
        check(WorkoutRouteRecorder.coreLocationErrorCode(typedUnknown) == .locationUnknown,
              "typed Core Location unknown classified")
        check(WorkoutRouteRecorder.coreLocationErrorCode(typedDenied) == .denied,
              "typed Core Location denial classified")
        check(WorkoutRouteRecorder.coreLocationErrorCode(error(.locationUnknown)) == .locationUnknown,
              "NSError Core Location domain classified")
        let foreignZero = NSError(domain: "Fixture.OtherDomain", code: 0)
        let foreignOne = NSError(domain: "Fixture.OtherDomain", code: 1)
        check(WorkoutRouteRecorder.coreLocationErrorCode(foreignZero) == nil,
              "foreign numeric zero is not locationUnknown")
        check(WorkoutRouteRecorder.coreLocationErrorCode(foreignOne) == nil,
              "foreign numeric one is not denied")
        check(WorkoutRouteRecorder.coreLocationErrorCode(NSError(domain: kCLErrorDomain, code: 999))?.rawValue == 999,
              "extensible Core Location code preserves unknown raw value")

        let f = Fixture()
        let recorder = f.recorder()
        recorder.start()
        for failure in [foreignZero, foreignOne, error(.network), error(.headingFailure),
                        NSError(domain: kCLErrorDomain, code: 999)] {
            recorder.receiveLocationError(failure)
            check(f.stops == 0 && f.starts == 1, "unestablished terminal error leaves stream active")
            check(recorder.diagnosticSummary(result: "capturing").contains(
                "locationError=\(failure.domain) code \(failure.code)"), "original error diagnostic preserved")
        }
        recorder.receiveLocationError(typedUnknown)
        check(f.stops == 0, "typed transient error leaves stream active")
        recorder.accept([f.point(1)])
        await recorder.stopAndDrain(at: Date())
        saved(await recorder.finishRoute(with: f.workout), accepted: 1, inserted: 1)
    }

    private static func denialAndIndependentWorkoutSave() async {
        // Model the unchanged caller boundary: workout saving completes
        // independently, then the recorder receives the saved HKWorkout object.
        // Neither missing route data nor route finishing failure may undo it.
        for hadPoint in [false, true] {
            let f = Fixture()
            let recorder = f.recorder()
            recorder.start()
            if hadPoint { recorder.accept([f.point(1)]) }
            recorder.receiveLocationError(CLError(_nsError: error(.denied)))
            check(f.stops == 1 && f.starts == 1, "denial stops collection without restart")
            check(recorder.diagnosticSummary(result: "stopped").contains("locationError=kCLErrorDomain code 1"),
                  "denial diagnostic preserved")
            await recorder.stopAndDrain(at: Date())
            var savedWorkouts: [HKWorkout] = []
            let saveWorkout = { savedWorkouts.append(f.workout); return f.workout }
            let savedWorkout = saveWorkout()
            check(savedWorkouts.map(\.uuid) == [savedWorkout.uuid], "independent workout save completes after denial")
            if hadPoint { f.finishError = NSError(domain: "Fixture.RouteFinish", code: 7) }
            let result = await recorder.finishRoute(with: savedWorkout)
            failed(result, containing: hadPoint ? "HealthKit Fixture.RouteFinish code 7" : "no accepted GPS points",
                   accepted: hadPoint ? 1 : 0, inserted: hadPoint ? 1 : 0)
            check(savedWorkouts.map(\.uuid) == [savedWorkout.uuid], "route failure preserves independently saved workout")
            check(f.finishedWorkouts.count == (hadPoint ? 1 : 0), "only inserted route attempts finalization")
        }

        let f = Fixture()
        let recorder = f.recorder()
        recorder.start()
        recorder.accept([f.point(1)])
        recorder.receiveLocationError(error(.denied))
        await recorder.stopAndDrain(at: Date())
        saved(await recorder.finishRoute(with: f.workout), accepted: 1, inserted: 1)
    }

    private static func callbacksAfterEnd() async {
        let f = Fixture()
        let recorder = f.recorder()
        recorder.start()
        recorder.accept([f.point(1)])
        recorder.receiveLocationError(error(.locationUnknown))
        await recorder.stopAndDrain(at: Date())
        let stoppedDiagnostic = recorder.diagnosticSummary(result: "stopped")
        for failure in [error(.locationUnknown), error(.denied), error(.network)] {
            recorder.receiveLocationError(failure)
        }
        recorder.authorizationDidChange(to: .authorizedAlways)
        recorder.authorizationDidChange(to: whenInUse)
        recorder.start()
        check(f.starts == 1 && f.stops == 1, "errors and authorization events after end cannot restart capture")
        check(recorder.diagnosticSummary(result: "stopped") == stoppedDiagnostic,
              "late errors do not overwrite workout diagnostic")
        recorder.accept([f.point(2)])
        saved(await recorder.finishRoute(with: f.workout), accepted: 1, inserted: 1)
        check(f.inserted.count == 1, "late location cannot enter saved route")
    }

    private static func authorizationAndUnavailableServices() async {
        let f = Fixture()
        f.authorization = .notDetermined
        let recorder = f.recorder()
        recorder.start()
        recorder.start()
        check(f.authorizationRequests == 1 && f.starts == 0, "undetermined authorization requested only once")
        recorder.authorizationDidChange(to: .denied)
        recorder.authorizationDidChange(to: .restricted)
        check(f.starts == 0, "unauthorized changes do not start collection")
        f.authorization = .authorizedAlways
        recorder.authorizationDidChange(to: f.authorization)
        recorder.authorizationDidChange(to: f.authorization)
        check(f.starts == 1, "grant starts existing service only once")
        recorder.receiveLocationError(error(.denied))
        recorder.authorizationDidChange(to: .authorizedAlways)
        check(f.starts == 2, "denial clears capturing for a later authorization grant")
        await recorder.stopAndDrain(at: Date())

        let unavailable = Fixture()
        unavailable.services = false
        let unavailableRecorder = unavailable.recorder()
        unavailableRecorder.start()
        check(unavailable.starts == 0 && unavailable.authorizationRequests == 0,
              "disabled location services preserve existing startup behavior")
        await unavailableRecorder.stopAndDrain(at: Date())
    }

    private static func filtering() async {
        let f = Fixture()
        let recorder = f.recorder()
        recorder.start()
        let first = f.point(1, accuracy: 50)
        let second = f.point(2, accuracy: 0)
        let input = [first, first, second, f.point(-1), f.point(3, accuracy: -1),
                     f.point(4, accuracy: 51), f.point(5, accuracy: .nan),
                     f.point(6, latitude: 91), f.point(7, latitude: .infinity),
                     f.point(3_600)]
        recorder.accept(input)
        await recorder.stopAndDrain(at: Date())
        saved(await recorder.finishRoute(with: f.workout), accepted: 2, inserted: 2)
        check(f.inserted.map(\.timestamp) == [first.timestamp, second.timestamp],
              "accuracy, coordinate, timestamp and duplicate filters preserved")
        check(recorder.diagnosticSummary(result: "saved").contains("received=10, accepted=2, inserted=2"),
              "received counts include rejected points")
    }

    private static func serializedInsertsAndConcurrentStop() async {
        let f = Fixture()
        let releaseFirstInsert = Gate()
        f.firstInsertGate = releaseFirstInsert
        let recorder = f.recorder()
        recorder.start()
        recorder.accept([f.point(1)])
        await f.firstInsertStarted.wait()
        recorder.receiveLocationError(error(.locationUnknown))
        recorder.accept([f.point(2)])
        let firstStop = Task { await recorder.stopAndDrain(at: Date()) }
        await f.stopped.wait()
        check(f.finishedWorkouts.isEmpty, "route not finished while insertion is pending")
        let secondStop = Task { await recorder.stopAndDrain(at: Date()) }
        releaseFirstInsert.open()
        await firstStop.value
        await secondStop.value
        check(f.maximumConcurrentInserts == 1, "inserts never overlap")
        check(f.events == ["start 0", "end 0", "start 1", "end 1"], "FIFO batch insertion and drain")
        check(f.stops == 1 && f.delegateClears == 1, "concurrent stops share one drain")
        saved(await recorder.finishRoute(with: f.workout), accepted: 2, inserted: 2)
        check(f.activeInserts == 0 && f.finishedWorkouts == [f.workout.uuid],
              "route finalizes only after all inserts complete")
    }

    private static func insertionFailureSalvagesEarlierPoints() async {
        let f = Fixture()
        f.failingInsertIndex = 1
        let recorder = f.recorder()
        recorder.start()
        recorder.accept([f.point(1)])
        recorder.accept([f.point(2)])
        recorder.accept([f.point(3)])
        await recorder.stopAndDrain(at: Date())
        saved(await recorder.finishRoute(with: f.workout), accepted: 3, inserted: 1)
        check(f.insertAttempts == 2 && f.inserted.count == 1, "fatal builder failure prevents queued insertion")
        check(f.stops == 2, "normal end and fatal insertion each stop service")
        recorder.accept([f.point(4)])
        check(recorder.diagnosticSummary(result: "saved").contains("insertError=Fixture.Insert code 9"),
              "fatal insertion diagnostic remains visible")
    }

    private static func finalizationGuardsAndFailure() async {
        let f = Fixture()
        let recorder = f.recorder()
        recorder.start()
        failed(await recorder.finishRoute(with: f.workout), containing: "invalid finalization state",
               accepted: 0, inserted: 0)
        check(f.finishedWorkouts.isEmpty, "cannot finish an active recorder")
        recorder.accept([f.point(1)])
        await recorder.stopAndDrain(at: Date())
        f.finishError = NSError(domain: "Fixture.RouteFinish", code: 7)
        failed(await recorder.finishRoute(with: f.workout), containing: "HealthKit Fixture.RouteFinish code 7",
               accepted: 1, inserted: 1)
        failed(await recorder.finishRoute(with: f.workout), containing: "invalid finalization state",
               accepted: 1, inserted: 1)
        check(f.finishedWorkouts == [f.workout.uuid], "failed finalization is not repeated")
    }

    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    @MainActor
    private final class Fixture {
        let start = Date().addingTimeInterval(-100)
        lazy var workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(60))
        var authorization = whenInUse
        var services = true
        var starts = 0
        var stops = 0
        var delegateClears = 0
        var authorizationRequests = 0
        var insertAttempts = 0
        var activeInserts = 0
        var maximumConcurrentInserts = 0
        var inserted: [CLLocation] = []
        var finishedWorkouts: [UUID] = []
        var events: [String] = []
        let firstInsertStarted = Gate()
        let stopped = Gate()
        var firstInsertGate: Gate?
        var failingInsertIndex: Int?
        var finishError: Error?

        func recorder() -> WorkoutRouteRecorder {
            WorkoutRouteRecorder(
                locationClient: .init(
                    authorizationStatus: { self.authorization },
                    servicesEnabled: { self.services },
                    requestAuthorization: { self.authorizationRequests += 1 },
                    startUpdatingLocation: { self.starts += 1 },
                    stopUpdatingLocation: { self.stops += 1; self.stopped.open() },
                    clearDelegate: { self.delegateClears += 1 }
                ),
                routeClient: .init(
                    insertRouteData: { locations in
                        let index = self.insertAttempts
                        self.insertAttempts += 1
                        self.activeInserts += 1
                        self.maximumConcurrentInserts = max(self.maximumConcurrentInserts, self.activeInserts)
                        self.events.append("start \(index)")
                        defer { self.activeInserts -= 1; self.events.append("end \(index)") }
                        if index == 0 {
                            self.firstInsertStarted.open()
                            await self.firstInsertGate?.wait()
                        }
                        if self.failingInsertIndex == index {
                            throw NSError(domain: "Fixture.Insert", code: 9)
                        }
                        self.inserted.append(contentsOf: locations)
                    },
                    finishRoute: { workout in
                        check(self.activeInserts == 0, "finish never overlaps insertion")
                        self.finishedWorkouts.append(workout.uuid)
                        if let failure = self.finishError { throw failure }
                    }
                ),
                startDate: start
            )
        }

        func point(_ offset: TimeInterval, accuracy: Double = 5, latitude: Double = 51) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: -0.1), altitude: 10,
                       horizontalAccuracy: accuracy, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(offset))
        }
    }
}
