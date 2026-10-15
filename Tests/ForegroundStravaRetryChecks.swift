import Foundation
import HealthKit

// Compile with the upload API/store/coordinator, saved-run selection, and run identity.
// All HealthKit workouts, transport responses, and timer deliveries are injected.
@main
@MainActor
struct ForegroundStravaRetryChecks {
    private static var checks = 0
    private enum Failure: Error { case export, offline }

    static func main() async throws {
        try enumerationAndRecovery()
        exactResolution()
        try await orderingAndMissingWorkouts()
        try await claimsAndCoalescing(duringPost: false)
        try await claimsAndCoalescing(duringPost: true)
        try await launchActivationAndEndRunOverlap()
        try await separateEntryInstancesRereadLedger()
        try await manualClaimWins()
        try await registrationDuringDrain()
        try await startupRecoveryAndUnavailableHealth()
        try await retriesAndBackoff()
        try await deactivationBeforePost()
        try await registrationWhileInactive()
        try await localFailureDoesNotBlockOthers()
        print("Foreground Strava retry checks passed (\(checks) assertions)")
    }

    private static func enumerationAndRecovery() throws {
        let f = try Fixture()
        defer { f.remove() }
        let phases: [PendingStravaUpload.Phase] = [
            .pending, .retryableFailure, .submitting, .accepted(uploadID: "1"),
            .processing(uploadID: "1"), .completed(uploadID: "1", activityID: 2),
            .failed(uploadID: nil), .duplicate(uploadID: nil), .outcomeUnknown
        ]
        var ids: [UUID] = []
        for phase in phases {
            let id = UUID()
            ids.append(id)
            var record = PendingStravaUpload(runID: id)
            switch phase {
            case .pending: break
            case .retryableFailure: record.preRequestFailed()
            default:
                check(record.beginSubmission(), "fixture begins submission")
                switch phase {
                case .submitting: break
                case .accepted: record.receive(status(.accepted))
                case .processing: record.receive(status(.processing))
                case .completed: record.receive(status(.completed(activityID: 2)))
                case .failed: record.rejected(duplicate: false)
                case .duplicate: record.rejected(duplicate: true)
                case .outcomeUnknown: record.postOutcomeUnknown()
                default: break
                }
            }
            try f.store.save(record)
        }
        check(try f.store.records().count == 9, "enumerates all valid durable records")
        check(Set(try f.store.eligibleRecords().map(\.runID)) == Set(ids.prefix(2)), "only pending/retryable enter queue")
        check(try f.store.loadOrCreate(runID: ids[2]).phase == .submitting, "ordinary reads preserve active submitting")
        let corruptID = UUID()
        let corrupt = f.store.directory.appendingPathComponent(corruptID.uuidString.lowercased() + ".json")
        try Data("corrupt".utf8).write(to: corrupt)
        let wrongID = UUID()
        let wrong = f.store.directory.appendingPathComponent(wrongID.uuidString.lowercased() + ".json")
        try JSONEncoder().encode(PendingStravaUpload(runID: UUID())).write(to: wrong)
        check(try f.store.records().count == 9, "corrupt and mismatched files excluded")
        try f.store.recoverInterruptedSubmissions()
        check(try f.store.load(runID: ids[2])?.phase == .outcomeUnknown, "startup recovery preserves ambiguity")
        check(try f.store.records().filter { $0.phase == .outcomeUnknown }.count == 2, "only submitting is recovered")
        check(FileManager.default.fileExists(atPath: corrupt.path), "corrupt record preserved")
        check(FileManager.default.fileExists(atPath: wrong.path), "mismatched record preserved")
    }

    private static func exactResolution() {
        let id = UUID()
        let correct = workout(id, at: 10)
        let newer = workout(UUID(), at: 100)
        let sources: Set<String> = [correct.sourceRevision.source.bundleIdentifier]
        check(PaceCoachSavedRunSelection.exact(runID: id, in: [newer, correct], acceptedSourceBundleIDs: sources)?.uuid == correct.uuid,
              "exact UUID selects older saved workout rather than latest")
        check(PaceCoachSavedRunSelection.exact(runID: UUID(), in: [correct], acceptedSourceBundleIDs: sources) == nil, "missing UUID unresolved")
        check(PaceCoachSavedRunSelection.exact(runID: id, in: [correct], acceptedSourceBundleIDs: ["another.app"]) == nil, "unrelated source rejected")
        check(PaceCoachSavedRunSelection.exact(runID: id, in: [correct, workout(id, at: 20)], acceptedSourceBundleIDs: sources) == nil, "duplicate metadata UUID is ambiguous")
        check(PaceCoachSavedRunSelection.exact(runID: id, in: [workout(id, at: 1, indoor: true)], acceptedSourceBundleIDs: sources) == nil, "indoor workout rejected")
        check(PaceCoachSavedRunSelection.exact(runID: id, in: [workout(id, at: 1, activity: .cycling)], acceptedSourceBundleIDs: sources) == nil, "other sport rejected")
    }

    private static func orderingAndMissingWorkouts() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let ids = [
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        ]
        for id in ids { _ = try f.store.loadOrCreate(runID: id) }
        let missing = UUID()
        _ = try f.store.loadOrCreate(runID: missing)
        let historical = workout(UUID(), at: 0)
        let saved = [workout(ids[0], at: 30), workout(ids[2], at: 10), workout(ids[1], at: 10), historical]
        var exported: [UUID] = []
        var posts = 0
        let flow = f.flow(workouts: saved, makeTCX: { _, id in
            exported.append(id)
            return f.file
        }, submit: { _ in posts += 1; return status(.accepted) })
        await flow.requestRetry()?.value
        check(exported == [ids[1], ids[2], ids[0]], "oldest first with UUID tie-break independent of directory/query ordering")
        check(posts == 3, "all three eligible runs POST once")
        check(try f.store.load(runID: missing)?.phase == .pending, "missing Health data preserves durable record")
        check(try f.store.load(runID: WorkoutRunIdentity.runID(in: historical)!) == nil, "no historical upload created")
        check(flow.scheduledRetryDelay == 30, "missing data receives bounded later opportunity")
        flow.setActive(false)
        f.clock.releaseAll()
        let reopened = f.flow(workouts: saved, submit: { _ in posts += 1; return status(.accepted) })
        await reopened.requestRetry()?.value
        check(posts == 3, "accepted records never repost on another drain/process")
        reopened.setActive(false)
        f.clock.releaseAll()
    }

    private static func claimsAndCoalescing(duringPost: Bool) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        _ = try f.store.loadOrCreate(runID: id)
        let gate = Gate()
        var exports = 0
        var posts = 0
        let flow = f.flow(workouts: [workout(id, at: 0)], makeTCX: { _, _ in
            exports += 1
            if !duringPost { await gate.wait() }
            return f.file
        }, submit: { _ in
            posts += 1
            if duringPost { await gate.wait() }
            return status(.accepted)
        })
        let first = flow.requestRetry()
        await until { gate.waiting }
        let second = flow.requestRetry()
        let third = flow.requestRetry()
        check(second != nil && third != nil, "overlapping triggers coalesce onto running drain")
        let manual = await flow.submitManually(runID: id, tcxFile: f.file)
        check(manual.record == nil, "manual path cannot claim automatic in-flight run")
        check(exports == 1 && posts == (duringPost ? 1 : 0), "one preparation/POST while suspended at await")
        let expected: PendingStravaUpload.Phase = duringPost ? .submitting : .pending
        check(try f.store.loadOrCreate(runID: id).phase == expected, "same-process reload never recovers active submission")
        check(try f.store.records().first?.phase == expected, "queue enumeration does not mutate active phase")
        gate.release()
        await first?.value
        await second?.value
        await third?.value
        check(posts == 1 && exports == 1, "one POST after all overlapping triggers finish")
        check(try f.store.load(runID: id)?.phase == .accepted(uploadID: "1"), "genuine response persists after concurrent reads")
        check(flow.scheduledRetryDelay == nil, "empty eligible queue schedules no retry")
    }

    private static func retriesAndBackoff() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let ids = [UUID(), UUID(), UUID()]
        for id in ids { _ = try f.store.loadOrCreate(runID: id) }
        var probes = 0
        var posts = 0
        var offline = true
        let flow = f.flow(workouts: ids.enumerated().map { workout($0.element, at: Double($0.offset)) },
                          preflight: { probes += 1; if offline { throw Failure.offline } },
                          submit: { _ in posts += 1; return status(.accepted) })
        await flow.requestRetry()?.value
        check(probes == 1 && posts == 0, "shared connectivity failure stops queue after one probe")
        for (index, delay) in [30.0, 60, 120, 300, 300].enumerated() {
            await until { f.clock.waiters.count == 1 }
            check(flow.scheduledRetryDelay == delay, "conservative increasing/capped delay")
            for _ in 0..<10 { check(flow.requestRetry() == nil, "trigger observes cooldown") }
            check(probes == index + 1, "overlapping triggers do not hammer offline queue")
            f.clock.fireNext()
            await until { probes == index + 2 && flow.scheduledRetryDelay != nil }
        }
        check(try f.store.eligibleRecords().count == 3, "all offline records remain safely eligible")
        offline = false
        await until { f.clock.waiters.count == 1 }
        f.clock.fireNext()
        await until { posts == 3 && flow.scheduledRetryDelay == nil }
        check(posts == 3, "safe failures retry later without manual Upload")
        check(try f.store.eligibleRecords().isEmpty, "all recovered responses durably blocked")
        flow.setActive(false)
        f.clock.releaseAll()
    }

    private static func launchActivationAndEndRunOverlap() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID(), saved = workout(id, at: 0)
        _ = try f.store.loadOrCreate(runID: id)
        let resolveGate = Gate(), postGate = Gate()
        var lookups = 0, exports = 0, posts = 0
        let flow = f.flow(initiallyActive: false, makeTCX: { _, runID in
            check(runID == id, "overlapping paths keep exact run UUID")
            exports += 1
            return f.file
        }, resolve: { _ in
            lookups += 1
            await resolveGate.wait()
            return [saved]
        }, submit: { _ in
            posts += 1
            await postGate.wait()
            return status(.accepted)
        })
        check(posts == 0 && lookups == 0, "startup recovery itself never dispatches")
        // These tasks model lifecycle callbacks arriving together on MainActor.
        let launch = Task { flow.requestRetry(trigger: .startup) }
        let activation = Task { flow.setActive(true) }
        _ = await launch.value
        await activation.value
        let drain = flow.requestRetry(trigger: .activation)
        await until { resolveGate.waiting }
        flow.setActive(true)
        _ = flow.requestRetry(trigger: .startup)
        _ = flow.requestRetry(trigger: .foregroundTimer)
        _ = flow.registerAndStart(savedWorkout: saved, runID: id)
        check(lookups == 1 && exports == 0, "launch/active/timer/End Run coalesce during Health query")
        resolveGate.release()
        await until { postGate.waiting }
        check(exports == 1 && posts == 1, "one POST reaches suspended transport")
        let manual = await flow.submitManually(runID: id, tcxFile: f.file)
        check(manual.record == nil, "manual entry cannot pass same-run claim during POST")
        flow.setActive(false)
        flow.setActive(true)
        _ = flow.registerAndStart(savedWorkout: saved, runID: id)
        check(try f.store.loadOrCreate(runID: id).phase == .submitting, "active submission survives reload and lifecycle changes")
        check(try f.store.eligibleRecords().isEmpty, "enumeration never recovers active submitting")
        postGate.release()
        await drain?.value
        await flow.requestRetry(trigger: .activation)?.value
        check(posts == 1 && lookups == 1 && exports == 1, "all entry paths preserve one POST after response")
        check(try f.store.load(runID: id)?.phase == .accepted(uploadID: "1"), "response remains durably blocked")
        flow.setActive(false)
        f.clock.releaseAll()
    }

    private static func separateEntryInstancesRereadLedger() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID(), saved = workout(id, at: 0)
        _ = try f.store.loadOrCreate(runID: id)
        let firstGate = Gate(), secondGate = Gate()
        var posts = 0
        // Production has one singleton. This also probes the durable handoff if
        // independently constructed entry points both finish preparation.
        let first = f.flow(workouts: [saved], preflight: { await firstGate.wait() }, submit: { _ in
            posts += 1
            return status(.accepted)
        })
        let second = f.flow(workouts: [saved], preflight: { await secondGate.wait() }, submit: { _ in
            posts += 1
            return status(.accepted)
        })
        let automatic = first.requestRetry(trigger: .activation)
        let manual = Task { await second.submitManually(runID: id, tcxFile: f.file) }
        await until { firstGate.waiting && secondGate.waiting }
        check(posts == 0, "both separately claimed paths are still pre-POST")
        firstGate.release()
        await automatic?.value
        check(posts == 1, "first durable handoff submits once")
        secondGate.release()
        _ = await manual.value
        check(posts == 1, "second entry rereads accepted state after await and cannot POST")
        check(try f.store.load(runID: id)?.phase == .accepted(uploadID: "1"), "suppressed entry cannot overwrite accepted record")
        first.setActive(false)
        second.setActive(false)
        f.clock.releaseAll()
    }

    private static func manualClaimWins() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        _ = try f.store.loadOrCreate(runID: id)
        let gate = Gate()
        var exports = 0, posts = 0
        let flow = f.flow(workouts: [workout(id, at: 0)], makeTCX: { _, _ in
            exports += 1
            return f.file
        }, preflight: { await gate.wait() }, submit: { _ in
            posts += 1
            return status(.accepted)
        })
        let manual = Task { await flow.submitManually(runID: id, tcxFile: f.file) }
        await until { gate.waiting }
        await flow.requestRetry()?.value
        check(exports == 0 && posts == 0, "automatic queue cannot claim manually preparing run")
        gate.release()
        let result = await manual.value
        check(posts == 1 && result.record?.phase == .accepted(uploadID: "1"), "manual control uses shared submission path")
        check(flow.scheduledRetryDelay == nil, "manual completion clears unnecessary timer")
        flow.setActive(false)
        f.clock.releaseAll()
    }

    private static func startupRecoveryAndUnavailableHealth() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let interrupted = UUID(), pending = UUID()
        var record = try f.store.loadOrCreate(runID: interrupted)
        check(record.beginSubmission(), "interrupted fixture starts")
        try f.store.save(record)
        _ = try f.store.loadOrCreate(runID: pending)
        var posts = 0
        let flow = f.flow(resolve: { _ in throw Failure.export }, submit: { _ in
            posts += 1
            return status(.accepted)
        })
        check(try f.store.load(runID: interrupted)?.phase == .outcomeUnknown, "coordinator startup recovers abandoned POST once")
        await flow.requestRetry()?.value
        check(posts == 0, "unavailable Health data cannot create an upload")
        check(try f.store.load(runID: pending)?.phase == .pending, "Health query failure preserves pending entry")
        check(flow.scheduledRetryDelay == 30, "Health query can be retried at another foreground opportunity")
        flow.setActive(false)
        f.clock.releaseAll()
    }

    private static func registrationDuringDrain() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let firstID = UUID(), nextID = UUID()
        _ = try f.store.loadOrCreate(runID: firstID)
        let gate = Gate()
        var exports: [UUID] = []
        var posts = 0
        let flow = f.flow(workouts: [workout(firstID, at: 0)], makeTCX: { _, id in
            exports.append(id)
            return f.file
        }, submit: { _ in
            posts += 1
            if posts == 1 { await gate.wait() }
            return status(.accepted)
        })
        let task = flow.requestRetry()
        await until { gate.waiting }
        check(flow.registerAndStart(savedWorkout: workout(nextID, at: 60), runID: nextID) != nil,
              "new End Run joins the existing drain")
        check(try f.store.load(runID: nextID)?.phase == .pending, "new run registered before existing upload completes")
        gate.release()
        await task?.value
        check(posts == 2 && exports == [firstID, nextID], "drain rescans new registrations without reposting first run")
        check(flow.scheduledRetryDelay == nil, "all newly registered work is drained")
    }

    private static func deactivationBeforePost() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        _ = try f.store.loadOrCreate(runID: id)
        let gate = Gate()
        var posts = 0
        let flow = f.flow(workouts: [workout(id, at: 0)], preflight: { await gate.wait() },
                          submit: { _ in posts += 1; return status(.accepted) })
        let task = flow.requestRetry()
        await until { gate.waiting }
        flow.setActive(false)
        gate.release()
        await task?.value
        check(posts == 0, "leaving active during preflight prevents POST")
        check(try f.store.load(runID: id)?.phase == .pending, "no in-flight marker before dispatch")
        check(flow.scheduledRetryDelay == nil, "inactive process has no retry timer")
        flow.setActive(true)
        await until { gate.waiting }
        gate.release()
        await until { posts == 1 }
        flow.setActive(false)
        f.clock.releaseAll()
    }

    private static func registrationWhileInactive() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var posts = 0
        let flow = f.flow(initiallyActive: false, submit: { _ in posts += 1; return status(.accepted) })
        check(flow.registerAndStart(savedWorkout: workout(id, at: 0), runID: id) == nil, "inactive End Run only registers")
        check(try f.store.load(runID: id)?.phase == .pending, "inactive run durably pending")
        check(posts == 0, "no POST without foreground opportunity")
        flow.setActive(true)
        await until { posts == 1 }
        check(try f.store.load(runID: id)?.phase == .accepted(uploadID: "1"), "activation recovers registered run")
        flow.setActive(false)
        f.clock.releaseAll()
    }

    private static func localFailureDoesNotBlockOthers() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let bad = UUID(), good = UUID()
        for id in [bad, good] { _ = try f.store.loadOrCreate(runID: id) }
        var posts = 0
        let flow = f.flow(workouts: [workout(bad, at: 0), workout(good, at: 1)], makeTCX: { _, id in
            if id == bad { throw Failure.export }
            return f.file
        }, submit: { _ in posts += 1; return status(.accepted) })
        await flow.requestRetry()?.value
        check(posts == 1, "one malformed export does not starve another run")
        check(try f.store.load(runID: bad)?.phase == .retryableFailure, "local export failure remains recoverable")
        flow.setActive(false)
        await until { f.clock.waiters.count == 1 }
        f.clock.fireNext() // Deliver an obsolete timer callback after cancellation.
        await Task.yield()
        check(posts == 1 && flow.scheduledRetryDelay == nil, "cancelled timer cannot restart drain")
    }

    private static func workout(_ id: UUID, at offset: Double, indoor: Bool = false,
                                activity: HKWorkoutActivityType = .running) -> HKWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + offset)
        return HKWorkout(activityType: activity, start: start, end: start.addingTimeInterval(60),
                         workoutEvents: nil, totalEnergyBurned: nil, totalDistance: nil,
                         metadata: [WorkoutRunIdentity.metadataKey: id.uuidString, HKMetadataKeyIndoorWorkout: indoor])
    }
    private static func status(_ state: StravaUploadStatus.State) -> StravaUploadStatus {
        StravaUploadStatus(uploadID: "1", externalID: nil, statusText: nil, state: state)
    }
    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    private static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Expected injected task/timer event was not delivered")
    }

    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { let c = continuation; continuation = nil; c?.resume() }
    }
    @MainActor private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var waiters: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
        func sleep(_ delay: TimeInterval) async { await withCheckedContinuation { waiters.append((delay, $0)) } }
        func fireNext() { let (delay, c) = waiters.removeFirst(); date += delay; c.resume() }
        func releaseAll() { let all = waiters; waiters = []; for (_, c) in all { c.resume() } }
    }
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: PendingStravaUploadStore
        let clock = Clock()
        var file: URL { root.appendingPathComponent("run.tcx") }
        init() throws { store = try PendingStravaUploadStore(directory: root) }
        func remove() { clock.releaseAll(); try? FileManager.default.removeItem(at: root) }
        func flow(workouts: [HKWorkout] = [], initiallyActive: Bool = true,
                  makeTCX: ((HKWorkout, UUID) async throws -> URL)? = nil,
                  resolve: (([UUID]) async throws -> [HKWorkout])? = nil,
                  preflight: @escaping () async throws -> Void = {},
                  submit: @escaping (URLRequest) async throws -> StravaUploadStatus) -> AutomaticStravaUploadFlow {
            let source = workout(UUID(), at: 0).sourceRevision.source.bundleIdentifier
            return AutomaticStravaUploadFlow(
                store: store, makeTCX: makeTCX ?? { _, _ in self.file },
                prepareRequest: { _, _ in URLRequest(url: URL(string: "https://example.invalid")!) },
                preflight: preflight, submitRequest: submit, resolveWorkouts: resolve ?? { _ in workouts },
                acceptedSources: [source], initiallyActive: initiallyActive,
                now: { self.clock.date }, sleep: { await self.clock.sleep($0) }
            )
        }
    }
}
