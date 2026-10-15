import Foundation
import HealthKit

// Compile with WorkoutRunIdentity.swift, StravaUploadAPI.swift,
// PendingStravaUpload.swift, ManualStravaUploadState.swift, and AutomaticStravaUploadFlow.swift.
// Uses a temporary ledger and injected closures; never contacts Health or Strava.
@main
struct AutomaticStravaUploadChecks {
    private enum FixtureError: Error { case beforePost }
    private static var checks = 0

    @MainActor
    static func main() async throws {
        try await successfulAndDuplicate()
        try await retryableMaySubmit()
        try await blockedPhases()
        try await prePostFailures()
        try await preflightFailures()
        try await ledgerChangedDuringPreflight()
        try await ambiguousPost()
        try sourceOrdering()
        print("Automatic Strava upload checks passed (\(checks) assertions)")
    }

    @MainActor
    private static func retryableMaySubmit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runID = UUID()
        var record = try fixture.store.loadOrCreate(runID: runID)
        record.preRequestFailed()
        try fixture.store.save(record)
        let events = EventLog()
        let flow = fixture.flow(submit: { _ in
            events.values.append("POST")
            return status("456", .completed(activityID: 789))
        })
        let task = flow.registerAndStart(savedWorkout: savedWorkout(runID: runID), runID: runID)
        await task?.value
        check(events.values == ["POST"], "retryable run makes one automatic POST")
        check(try fixture.store.load(runID: runID)?.phase == .completed(uploadID: "456", activityID: 789),
              "completed activity and upload IDs persist")
    }

    @MainActor
    private static func successfulAndDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runID = UUID()
        let workout = savedWorkout(runID: runID)
        let originalWorkoutID = workout.uuid
        let events = EventLog()
        events.values = ["workout saved", "route finalized"]
        let flow = fixture.flow(
            makeTCX: { _, _ in
                events.values.append("TCX")
                let record = try fixture.store.load(runID: runID)
                check(record?.phase == .pending, "saved workout durably pending before TCX")
                return fixture.file
            },
            preflight: {
                events.values.append("HEAD")
                check(try fixture.store.load(runID: runID)?.phase == .pending,
                      "preflight precedes durable submitting marker")
            },
            submit: { _ in
                events.values.append("POST")
                return status("123", .accepted)
            }
        )
        let task = flow.registerAndStart(savedWorkout: workout, runID: runID)
        check(task != nil, "completed workout schedules immediate attempt")
        check(flow.registerAndStart(savedWorkout: workout, runID: runID) == nil,
              "duplicate completion callback cannot schedule a second POST")
        await task?.value
        check(events.values == ["workout saved", "route finalized", "TCX", "HEAD", "POST"],
              "export and POST follow saved workout and route")
        check(try fixture.store.load(runID: runID)?.phase == .accepted(uploadID: "123"),
              "accepted response persists")
        check(workout.uuid == originalWorkoutID && WorkoutRunIdentity.runID(in: workout) == runID,
              "Strava flow does not alter the saved workout")
    }

    @MainActor
    private static func blockedPhases() async throws {
        let phases: [PendingStravaUpload.Phase] = [
            .accepted(uploadID: "1"), .processing(uploadID: "1"),
            .completed(uploadID: "1", activityID: 2), .outcomeUnknown,
            .failed(uploadID: nil), .duplicate(uploadID: nil)
        ]
        for phase in phases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let runID = UUID()
            var record = try fixture.store.loadOrCreate(runID: runID)
            // Persist each legitimate terminal/accepted state through the state machine.
            if phase == .outcomeUnknown {
                check(record.beginSubmission(), "fixture submitting")
                record.postOutcomeUnknown()
            } else {
                check(record.beginSubmission(), "fixture submitting")
                switch phase {
                case .accepted: record.receive(status("1", .accepted))
                case .processing: record.receive(status("1", .processing))
                case .completed: record.receive(status("1", .completed(activityID: 2)))
                case .failed: record.rejected(duplicate: false)
                case .duplicate: record.rejected(duplicate: true)
                default: break
                }
            }
            try fixture.store.save(record)
            let events = EventLog()
            let flow = fixture.flow(submit: { _ in
                events.values.append("POST")
                return status("9", .accepted)
            })
            check(flow.registerAndStart(savedWorkout: savedWorkout(runID: runID), runID: runID) == nil,
                  "blocked phase does not start")
            check(events.values.isEmpty, "blocked phase never POSTs")
            check(try fixture.store.load(runID: runID)?.phase == phase, "blocked phase remains durable")
        }
    }

    @MainActor
    private static func prePostFailures() async throws {
        for failurePoint in ["TCX", "credentials"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let runID = UUID()
            let events = EventLog()
            let flow = fixture.flow(
                makeTCX: { _, _ in
                    if failurePoint == "TCX" { throw FixtureError.beforePost }
                    return fixture.file
                },
                prepare: { _, _ in
                    if failurePoint == "credentials" { throw FixtureError.beforePost }
                    return URLRequest(url: URL(string: "https://example.invalid")!)
                },
                submit: { _ in
                    events.values.append("POST")
                    return status("1", .accepted)
                }
            )
            let workout = savedWorkout(runID: runID)
            let task = flow.registerAndStart(savedWorkout: workout, runID: runID)
            await task?.value
            check(try fixture.store.load(runID: runID)?.phase == .retryableFailure,
                  "\(failurePoint) failure remains durably retryable")
            check(events.values.isEmpty, "\(failurePoint) failure makes no POST")
            check(WorkoutRunIdentity.runID(in: workout) == runID,
                  "\(failurePoint) failure leaves HealthKit workout intact")
        }
    }

    @MainActor
    private static func preflightFailures() async throws {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .timedOut, .networkConnectionLost, .cancelled,
            .secureConnectionFailed, .dataNotAllowed, .unknown
        ]
        for code in codes {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let runID = UUID()
            let events = EventLog()
            let flow = fixture.flow(preflight: {
                events.values.append("HEAD")
                check(try fixture.store.load(runID: runID)?.phase == .pending,
                      "probe has no submitting upload record")
                throw URLError(code)
            }, submit: { _ in
                events.values.append("POST")
                return status("1", .accepted)
            })
            let task = flow.registerAndStart(savedWorkout: savedWorkout(runID: runID), runID: runID)
            await task?.value
            check(events.values == ["HEAD"], "probe failure never starts POST")
            let reopened = try fixture.store.loadOrCreate(runID: runID)
            check(reopened.phase == .retryableFailure && reopened.isPostEligible,
                  "probe failure remains durably retryable regardless of error code")
            check(flow.registerAndStart(savedWorkout: savedWorkout(runID: runID), runID: runID) == nil,
                  "duplicate callback does not retry the probe or upload")
        }
    }

    @MainActor
    private static func ledgerChangedDuringPreflight() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runID = UUID()
        let events = EventLog()
        let flow = fixture.flow(preflight: {
            // Simulate a manual submission winning while the HEAD was awaited.
            var record = try fixture.store.loadOrCreate(runID: runID)
            check(record.beginSubmission(), "manual competitor starts")
            record.receive(status("9", .accepted))
            try fixture.store.save(record)
        }, submit: { _ in
            events.values.append("POST")
            return status("1", .accepted)
        })
        let task = flow.registerAndStart(savedWorkout: savedWorkout(runID: runID), runID: runID)
        await task?.value
        check(events.values.isEmpty, "fresh ledger check prevents POST after preflight suspension")
        check(try fixture.store.load(runID: runID)?.phase == .accepted(uploadID: "9"),
              "competitor's accepted response is preserved")
    }

    @MainActor
    private static func ambiguousPost() async throws {
        let failures: [Error] = [
            StravaUploadError.network, StravaUploadError.invalidResponse, StravaUploadError.httpStatus(503),
            URLError(.notConnectedToInternet), URLError(.cannotFindHost), URLError(.cannotConnectToHost),
            URLError(.timedOut), URLError(.networkConnectionLost), URLError(.cancelled),
            URLError(.secureConnectionFailed), URLError(.dataNotAllowed), URLError(.unknown)
        ]
        for failure in failures {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let runID = UUID()
            let events = EventLog()
            let flow = fixture.flow(submit: { _ in
                events.values.append("POST")
                check(try fixture.store.load(runID: runID)?.phase == .submitting,
                      "POST starts only with durable submitting marker")
                throw failure
            })
            let task = flow.registerAndStart(savedWorkout: savedWorkout(runID: runID), runID: runID)
            await task?.value
            check(events.values == ["POST"], "one automatic POST on network failure")
            check(try fixture.store.load(runID: runID)?.phase == .outcomeUnknown,
                  "ambiguous POST persists outcomeUnknown")
            let afterRelaunch = fixture.flow(submit: { _ in
                events.values.append("second POST")
                return status("2", .accepted)
            })
            check(afterRelaunch.registerAndStart(savedWorkout: savedWorkout(runID: runID), runID: runID) == nil,
                  "unknown outcome cannot repost after relaunch")
            check(events.values == ["POST"], "no duplicate POST")
        }
    }

    private static func sourceOrdering() throws {
        let manager = try String(contentsOfFile: "PaceCoach Watch App/HealthKit/WorkoutManager.swift",
                                 encoding: .utf8)
        let finish = manager[manager.range(of: "private func finishWorkout(at endDate:")!.lowerBound...]
        let save = finish.range(of: "workoutBuilder.finishWorkout()")!.lowerBound
        let route = finish.range(of: "routeRecorder.finishRoute(with: savedWorkout)")!.lowerBound
        let handoff = finish.range(of: "AutomaticStravaUploadFlow.shared.registerAndStart(")!.lowerBound
        let resume = finish.range(of: "endContinuation?.resume()")!.lowerBound
        check(save < route && route < handoff && handoff < resume,
              "manager hands off only after HealthKit save and route finalization")
    }

    private static func savedWorkout(runID: UUID) -> HKWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return HKWorkout(activityType: .running, start: start,
                         end: start.addingTimeInterval(60), workoutEvents: nil,
                         totalEnergyBurned: nil, totalDistance: nil,
                         metadata: [WorkoutRunIdentity.metadataKey: runID.uuidString])
    }

    private static func status(_ id: String, _ state: StravaUploadStatus.State) -> StravaUploadStatus {
        StravaUploadStatus(uploadID: id, externalID: nil, statusText: nil, state: state)
    }

    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    @MainActor
    private final class EventLog { var values: [String] = [] }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: PendingStravaUploadStore
        var file: URL { root.appendingPathComponent("run.tcx") }

        init() throws { store = try PendingStravaUploadStore(directory: root) }
        func remove() { try? FileManager.default.removeItem(at: root) }

        func flow(
            makeTCX: ((HKWorkout, UUID) async throws -> URL)? = nil,
            prepare: ((URL, UUID) async throws -> URLRequest)? = nil,
            preflight: @escaping () async throws -> Void = {},
            submit: @escaping (URLRequest) async throws -> StravaUploadStatus
        ) -> AutomaticStravaUploadFlow {
            AutomaticStravaUploadFlow(
                store: store,
                makeTCX: makeTCX ?? { _, _ in self.file },
                prepareRequest: prepare ?? { _, _ in URLRequest(url: URL(string: "https://example.invalid")!) },
                preflight: preflight,
                submitRequest: submit,
                acceptedSources: [savedWorkout(runID: UUID()).sourceRevision.source.bundleIdentifier]
            )
        }
    }
}
