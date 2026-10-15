import Foundation
import HealthKit

// Compile with the same sources as ForegroundStravaRetryChecks. All transport,
// clocks, and persistence are local fixtures; never contacts Health or Strava.
@main
@MainActor
struct StravaStatusReconciliationChecks {
    private static var checks = 0

    static func main() async throws {
        try legacyAndAttemptPersistence()
        try await transitionsAndBlockedPhases()
        try await boundedOrderingAndFairness()
        try await coalescingAndManualOwnership()
        try await manualRequestOutlivesTimer()
        try await staleResponseAndDeactivation()
        try await failuresAndDurableCooldown()
        try await successfulRateLimitAndMixedTimers()
        try await postDeadlineExpiresDuringGET()
        try await localFailuresDoNotStarve()
        try await persistenceFailures()
        try await postHandoffAndUnavailableHealth()
        try await timerAndBackoff()
        print("Strava status reconciliation checks passed (\(checks) assertions)")
    }

    private static func legacyAndAttemptPersistence() throws {
        let f = try Fixture(); defer { f.remove() }
        var record = try f.add(1)
        let path = f.store.directory.appendingPathComponent(record.runID.uuidString.lowercased() + ".json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        for key in ["workoutStartDate", "lastStatusAttemptAt", "nextStatusCheckAt", "statusBackoffStep"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        record = try f.store.load(runID: record.runID)!
        check(record.canCheckStatus && !record.isPostEligible, "legacy accepted JSON retains invariant")
        check(record.workoutStartDate == nil && record.nextStatusCheckAt == nil, "missing legacy metadata is immediately eligible")
        check(record.beginStatusCheck(at: f.clock.date), "known upload can persist GET attempt")
        try f.store.save(record)
        let reopened = try f.store.load(runID: record.runID)!
        check(reopened.phase == record.phase, "GET never uses submitting phase")
        check(reopened.lastStatusAttemptAt == f.clock.date, "attempt date durable")
        check(reopened.nextStatusCheckAt == f.clock.date + 30, "first GET cooldown durable")
        check(!reopened.isPostEligible, "GET attempt never permits POST")
    }

    private static func transitionsAndBlockedPhases() async throws {
        let f = try Fixture(); defer { f.remove() }
        for i in 1...3 { _ = try f.add(i, start: Double(i)) }
        var seen: [String] = []
        let flow = f.flow { id in
            seen.append(id)
            let states: [String: StravaUploadStatus.State] = ["1": .completed(activityID: 5_000_000_001), "2": .failed(message: "private server error"), "3": .duplicate(message: "private duplicate")]
            return response(id, states[id]!)
        }
        await flow.requestRetry()?.value
        check(seen == ["1", "2", "3"], "oldest saved run checked first")
        check(try f.store.load(runID: uuid(1))?.phase == .completed(uploadID: "1", activityID: 5_000_000_001), "64-bit activity ID persists")
        check(try f.store.load(runID: uuid(2))?.phase == .failed(uploadID: "2"), "processing failure retains upload ID")
        check(try f.store.load(runID: uuid(3))?.phase == .duplicate(uploadID: "3"), "duplicate terminal retains upload ID")
        check(flow.scheduledRetryDelay == nil, "terminal queue needs no timer")
        var unknown = PendingStravaUpload(runID: uuid(4)); _ = unknown.beginSubmission(); unknown.postOutcomeUnknown(); try f.store.save(unknown)
        await flow.requestRetry()?.value
        check(seen.count == 3, "terminal and unknown phases never GET or POST")
        check(try f.store.load(runID: uuid(4))?.phase == .outcomeUnknown, "unknown stays blocked")
        let json = String(decoding: try JSONEncoder().encode(f.store.load(runID: uuid(2))!), as: UTF8.self)
        check(!json.contains("private server error"), "raw remote error is not persisted")
        f.stop(flow)
    }

    private static func boundedOrderingAndFairness() async throws {
        let f = try Fixture(); defer { f.remove() }
        for i in (1...5).reversed() { _ = try f.add(i, start: Double(i)) }
        var seen: [String] = []
        let flow = f.flow { id in seen.append(id); return response(id, .processing) }
        await flow.requestRetry()?.value
        check(seen == ["1", "2", "3"], "batch limited to three checks")
        check(flow.scheduledRetryDelay == 30, "batch pacing leaves a bounded next opportunity")
        f.clock.date += 30
        await flow.requestRetry()?.value
        check(Array(seen.suffix(3)) == ["4", "5", "1"], "unattempted runs precede oldest still-processing run")
        check(try f.store.load(runID: uuid(1))?.phase == .processing(uploadID: "1"), "processing remains durable")
        check(try f.store.records().allSatisfy { !$0.isPostEligible }, "all status candidates remain POST blocked")
        f.stop(flow)
    }

    private static func coalescingAndManualOwnership() async throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.add(1); _ = try f.add(2)
        let gate = Gate(); var calls = 0
        let flow = f.flow { id in calls += 1; await gate.wait(); return response(id, .completed(activityID: Int64(id)!)) }
        let first = flow.requestRetry(trigger: .startup)
        await until { gate.waiting }
        let second = flow.requestRetry(trigger: .activation)
        let third = flow.requestRetry(trigger: .foregroundTimer)
        let manual = await flow.reconcileManually(runID: uuid(1))
        let other = await flow.reconcileManually(runID: uuid(2))
        check(manual.record?.canCheckStatus == true && other.record?.canCheckStatus == true, "busy manual controls reload durable state")
        check(calls == 1 && second != nil && third != nil, "lifecycle/manual overlap owns one status transport")
        gate.release(); await until { gate.waiting }
        gate.release(); await first?.value; await second?.value; await third?.value
        check(calls == 2, "one GET per due run despite overlapping triggers")
        let terminal = await flow.reconcileManually(runID: uuid(1))
        check(terminal.record?.phase == .completed(uploadID: "1", activityID: 1) && calls == 2, "stale manual view cannot recheck terminal record")
        f.stop(flow)

        let m = try Fixture(); defer { m.remove() }; _ = try m.add(1)
        let manualGate = Gate(); var manualCalls = 0
        let manualFlow = m.flow { id in manualCalls += 1; await manualGate.wait(); return response(id, .processing) }
        let task = Task { await manualFlow.reconcileManually(runID: uuid(1)) }
        await until { manualGate.waiting }; await manualFlow.requestRetry()?.value
        check(manualCalls == 1, "manual claim wins against lifecycle drain")
        manualGate.release(); _ = await task.value
        check(try m.store.load(runID: uuid(1))?.phase == .processing(uploadID: "1"), "manual result persists through shared operation")
        m.stop(manualFlow)
    }

    private static func staleResponseAndDeactivation() async throws {
        for terminalCompetitor in [false, true] {
            let f = try Fixture(); defer { f.remove() }; _ = try f.add(1); _ = try f.add(2)
            let gate = Gate(); var calls = 0
            let flow = f.flow { id in calls += 1; await gate.wait(); return response(id, .processing) }
            let task = flow.requestRetry(); await until { gate.waiting }
            if terminalCompetitor {
                var latest = try f.store.load(runID: uuid(1))!; latest.receive(response("1", .completed(activityID: 77)).status); try f.store.save(latest)
            }
            flow.setActive(false); gate.release(); await task?.value
            let expected: PendingStravaUpload.Phase = terminalCompetitor ? .completed(uploadID: "1", activityID: 77) : .processing(uploadID: "1")
            check(try f.store.load(runID: uuid(1))?.phase == expected, "late response saves unless a terminal record already won")
            check(calls == 1 && flow.scheduledRetryDelay == nil, "deactivation prevents next GET and timer")
            f.stop(flow)
        }
    }

    private static func manualRequestOutlivesTimer() async throws {
        let f = try Fixture(); defer { f.remove() }; _ = try f.add(1)
        let gate = Gate(); var calls = 0
        let flow = f.flow { id in
            calls += 1
            if calls > 1 { await gate.wait() }
            return response(id, .processing)
        }
        await flow.requestRetry()?.value
        await until { f.clock.waiters.count == 1 }
        f.clock.date += 30
        let manual = Task { await flow.reconcileManually(runID: uuid(1)) }
        await until { gate.waiting }
        f.clock.fireNext()
        await until { flow.scheduledRetryDelay == nil }
        await flow.requestRetry()?.value
        check(calls == 2 && flow.scheduledRetryDelay == nil, "long manual GET owns transport without overdue timer churn")
        gate.release(); _ = await manual.value
        check(flow.scheduledRetryDelay == 30, "manual completion restores the remaining durable deadline")
        f.stop(flow)
    }

    private static func successfulRateLimitAndMixedTimers() async throws {
        let f = try Fixture(); defer { f.remove() }; _ = try f.add(1); _ = try f.add(2)
        let deadline = f.clock.date + 3600; var calls = 0
        let flow = f.flow { id in calls += 1; return .init(status: response(id, .completed(activityID: 1)).status, retryNotBefore: deadline) }
        await flow.requestRetry()?.value
        check(calls == 1 && flow.scheduledRetryDelay == 3600, "successful exhausted-budget response stops batch until reset")
        check(try f.store.load(runID: uuid(1))?.phase == .completed(uploadID: "1", activityID: 1), "completion persists even when response exhausts quota")
        flow.setActive(false); flow.setActive(true); await flow.requestRetry()?.value
        check(calls == 1, "successful rate deadline survives activation")
        f.stop(flow)
        let reopened = f.flow { id in calls += 1; return response(id, .processing) }
        await reopened.requestRetry()?.value
        check(calls == 1 && reopened.scheduledRetryDelay == 3600, "terminal record's shared quota survives relaunch for other runs")
        f.stop(reopened)

        let m = try Fixture(); defer { m.remove() }
        var accepted = try m.add(1); _ = accepted.beginStatusCheck(at: m.clock.date); try m.store.save(accepted)
        _ = try m.store.loadOrCreate(runID: uuid(2))
        var lookups = 0, gets = 0
        let mixed = m.flow(resolve: { _ in lookups += 1; return [] }) { id in gets += 1; return response(id, .processing) }
        await mixed.requestRetry()?.value
        check(lookups == 1 && gets == 0 && mixed.scheduledRetryDelay == 30, "POST and GET deadlines initially coincide")
        m.clock.date += 30; await mixed.requestRetry()?.value
        check(lookups == 2 && gets == 1 && mixed.scheduledRetryDelay == 60, "both queues advance independent backoff at due time")
        // A second legacy accepted record creates a GET opportunity sooner than
        // the pending run's next Health/export opportunity.
        _ = try m.add(3); m.clock.date += 30; await mixed.requestRetry()?.value
        check(lookups == 2 && gets == 2, "earlier GET opportunity does not bypass POST cooldown")
        check(mixed.scheduledRetryDelay == 30, "earlier GET does not extend existing POST deadline")
        m.stop(mixed)
    }

    private static func failuresAndDurableCooldown() async throws {
        let failures: [Error] = [StravaUploadError.network, StravaUploadError.httpStatus(401), StravaUploadError.httpStatus(403), StravaUploadError.httpStatus(503), StravaUploadError.statusDeferred(until: Date(timeIntervalSince1970: 1_700_010_000))]
        for failure in failures {
            let f = try Fixture(); defer { f.remove() }; for i in 1...4 { _ = try f.add(i) }
            var calls = 0
            let flow = f.flow { _ in calls += 1; throw failure }
            await flow.requestRetry()?.value
            check(calls == 1, "shared failure stops remaining status batch")
            check(try f.store.load(runID: uuid(1))?.phase == .accepted(uploadID: "1"), "transport failure preserves known upload phase")
            flow.setActive(false); flow.setActive(true); await flow.requestRetry()?.value
            check(calls == 1, "activation cannot bypass shared cooldown")
            f.stop(flow)
            let reopened = f.flow { _ in calls += 1; throw failure }
            await reopened.requestRetry()?.value
            check(calls == 1 && reopened.scheduledRetryDelay! >= 30, "shared cooldown survives coordinator relaunch")
            check(try f.store.records().count == 4, "policy file does not become an upload record")
            f.stop(reopened)
        }
    }

    private static func postDeadlineExpiresDuringGET() async throws {
        let f = try Fixture(); defer { f.remove() }
        var accepted = try f.add(1)
        _ = accepted.beginStatusCheck(at: f.clock.date - 10)
        try f.store.save(accepted)
        _ = try f.store.loadOrCreate(runID: uuid(2))
        let gate = Gate(); var lookups = 0
        let flow = f.flow(resolve: { _ in lookups += 1; return [] }) { id in await gate.wait(); return response(id, .processing) }
        await flow.requestRetry()?.value
        check(lookups == 1 && flow.scheduledRetryDelay == 20, "GET deadline precedes independent POST deadline")
        f.clock.date += 20
        let task = flow.requestRetry(); await until { gate.waiting }
        check(lookups == 1, "POST opportunity has not yet been consumed")
        f.clock.date += 20; gate.release(); await task?.value
        check(flow.scheduledRetryDelay == 1, "GET crossing POST deadline schedules prompt unconsumed POST opportunity")
        await flow.requestRetry()?.value
        check(lookups == 2, "expired POST deadline is consumed by POST queue instead of skipped backoff")
        f.stop(flow)
    }

    private static func localFailuresDoNotStarve() async throws {
        for failure in [StravaUploadError.httpStatus(404), .invalidResponse, .duplicate] {
            let f = try Fixture(); defer { f.remove() }; _ = try f.add(1); _ = try f.add(2)
            var seen: [String] = []
            let flow = f.flow { id in seen.append(id); if id == "1" { throw failure }; return response(id, .completed(activityID: 2)) }
            await flow.requestRetry()?.value
            check(seen == ["1", "2"], "record-local failure allows next record")
            check(try f.store.load(runID: uuid(1))?.phase == .accepted(uploadID: "1"), "HTTP fault is never terminal processing evidence")
            check(try f.store.load(runID: uuid(2))?.phase == .completed(uploadID: "2", activityID: 2), "later run completes")
            f.stop(flow)
        }
        let f = try Fixture(); defer { f.remove() }; _ = try f.add(1)
        let flow = f.flow { _ in response("999", .completed(activityID: 99)) }
        await flow.requestRetry()?.value
        check(try f.store.load(runID: uuid(1))?.phase == .accepted(uploadID: "1"), "wrong response ID cannot mutate known upload")
        f.stop(flow)
    }

    private static func persistenceFailures() async throws {
        let f = try Fixture(); defer { f.remove() }; _ = try f.add(1)
        let policy = f.store.directory.appendingPathComponent("status-policy.json")
        try Data("corrupt".utf8).write(to: policy)
        var calls = 0
        let flow = f.flow { id in calls += 1; return response(id, .processing) }
        await flow.requestRetry()?.value
        check(calls == 0, "unreadable status policy fails closed before transport")
        f.stop(flow)

        let b = try Fixture(); defer { b.remove() }; _ = try b.add(1)
        // A directory at the policy path makes atomic policy persistence fail.
        try FileManager.default.createDirectory(at: b.store.directory.appendingPathComponent("status-policy.json"), withIntermediateDirectories: true)
        let before = b.flow { id in calls += 1; return response(id, .processing) }
        await before.requestRetry()?.value
        check(calls == 0, "policy write/read failure dispatches no GET")
        b.stop(before)

        let readonly = try Fixture(); defer { readonly.remove() }; _ = try readonly.add(1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonly.store.directory.path)
        let writeBlocked = readonly.flow { id in calls += 1; return response(id, .processing) }
        await writeBlocked.requestRetry()?.value
        check(writeBlocked.scheduledRetryDelay == 60, "failed cooldown write retains conservative in-memory pacing")
        for _ in 0..<5 { check(writeBlocked.requestRetry() == nil, "unwritable attempt cannot create a disk/timer retry loop") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonly.store.directory.path)
        check(calls == 0, "attempt write failure sends no GET")
        check(try readonly.store.load(runID: uuid(1))?.lastStatusAttemptAt == nil, "failed attempt persistence does not invent submission state")
        readonly.stop(writeBlocked)

        let a = try Fixture(); defer { a.remove() }; _ = try a.add(1)
        let after = a.flow { id in
            calls += 1
            let path = a.store.directory.appendingPathComponent(uuid(1).uuidString.lowercased() + ".json")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return response(id, .completed(activityID: 1))
        }
        await after.requestRetry()?.value
        check(calls == 1, "result persistence failure cannot repost or immediately retry")
        check((try? a.store.load(runID: uuid(1))) == nil, "unreadable result remains excluded")
        a.stop(after)

        let result = try Fixture(); defer { result.remove() }; _ = try result.add(1)
        let cannotSave = result.flow { id in
            calls += 1
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: result.store.directory.path)
            return response(id, .completed(activityID: 1))
        }
        await cannotSave.requestRetry()?.value
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: result.store.directory.path)
        let retained = try result.store.load(runID: uuid(1))!
        check(calls == 2 && retained.phase == .accepted(uploadID: "1"), "failed result write retains known upload for another GET")
        check(retained.nextStatusCheckAt == result.clock.date + 30 && !retained.isPostEligible, "failed result persistence retains pre-dispatch cooldown and POST block")
        check(cannotSave.scheduledRetryDelay == 60, "result/cooldown write failure also preserves in-memory pacing")
        result.stop(cannotSave)
    }

    private static func postHandoffAndUnavailableHealth() async throws {
        let f = try Fixture(); defer { f.remove() }; _ = try f.add(1)
        _ = try f.store.loadOrCreate(runID: uuid(2))
        var calls = 0
        let flow = f.flow(resolve: { _ in throw StravaUploadError.network }) { id in calls += 1; return response(id, .completed(activityID: 1)) }
        await flow.requestRetry()?.value
        check(calls == 1, "unavailable Health data does not block known-ID reconciliation")
        check(try f.store.load(runID: uuid(2))?.phase == .pending, "missing Health record remains safely pending")
        f.stop(flow)

        let p = try Fixture(); defer { p.remove() }
        let runID = uuid(3), start = p.clock.date
        let workout = HKWorkout(activityType: .running, start: start, end: start + 60, workoutEvents: nil, totalEnergyBurned: nil, totalDistance: nil, metadata: [WorkoutRunIdentity.metadataKey: runID.uuidString])
        var posts = 0, gets = 0
        let source = workout.sourceRevision.source.bundleIdentifier
        let postFlow = AutomaticStravaUploadFlow(store: p.store, makeTCX: { _, _ in p.root }, prepareRequest: { _, _ in URLRequest(url: URL(string: "https://example.invalid")!) }, preflight: {}, submitRequest: { _ in posts += 1; return response("3", .accepted).status }, checkStatus: { id in gets += 1; return response(id, .completed(activityID: 3)) }, acceptedSources: [source], now: { p.clock.date }, sleep: { await p.clock.sleep($0) })
        await postFlow.registerAndStart(savedWorkout: workout, runID: runID)?.value
        check(posts == 1 && gets == 0, "accepted POST schedules a later GET instead of immediate poll")
        check(try p.store.load(runID: runID)?.workoutStartDate == start, "new registration stores chronological date")
        p.clock.date += 30; await postFlow.requestRetry()?.value
        check(posts == 1 && gets == 1, "later recovery checks status without another POST")
        check(try p.store.load(runID: runID)?.phase == .completed(uploadID: "3", activityID: 3), "POST to automatic completion persists")
        p.stop(postFlow)
    }

    private static func timerAndBackoff() async throws {
        let f = try Fixture(); defer { f.remove() }; _ = try f.add(1)
        var calls = 0
        let flow = f.flow { id in calls += 1; return response(id, .processing) }
        await flow.requestRetry()?.value
        for delay in [30.0, 60, 120, 300, 900, 3600, 3600] {
            check(flow.scheduledRetryDelay == delay, "processing polls back off and cap at one hour")
            let previous = calls
            for _ in 0..<5 { await flow.requestRetry()?.value }
            check(calls == previous, "repeated triggers respect durable per-run delay")
            await until { !f.clock.waiters.isEmpty }; f.clock.fireNext()
            await until { calls == previous + 1 && flow.scheduledRetryDelay != nil }
        }
        check(try f.store.load(runID: uuid(1))?.canCheckStatus == true, "persistent processing never becomes repost eligible")
        f.stop(flow)
    }

    private static func uuid(_ i: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))! }
    private static func response(_ id: String, _ state: StravaUploadStatus.State) -> StravaStatusCheckResponse { .init(status: .init(uploadID: id, externalID: nil, statusText: nil, state: state), retryNotBefore: nil) }
    private static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    private static func until(_ predicate: () -> Bool) async { for _ in 0..<10000 { if predicate() { return }; await Task.yield() }; preconditionFailure("Injected event not delivered") }
    @MainActor private final class Gate {
        var c: CheckedContinuation<Void, Never>?
        var waiting: Bool { c != nil }
        func wait() async { await withCheckedContinuation { c = $0 } }
        func release() { let old = c; c = nil; old?.resume() }
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
        init() throws { store = try PendingStravaUploadStore(directory: root) }
        func add(_ i: Int, start: Double? = nil) throws -> PendingStravaUpload {
            var record = PendingStravaUpload(runID: uuid(i), workoutStartDate: start.map { Date(timeIntervalSince1970: $0) })
            _ = record.beginSubmission(); record.receive(response(String(i), .accepted).status); try store.save(record); return record
        }
        func flow(resolve: @escaping ([UUID]) async throws -> [HKWorkout] = { _ in preconditionFailure("Status recovery queried HealthKit") }, status: @escaping (String) async throws -> StravaStatusCheckResponse) -> AutomaticStravaUploadFlow {
            AutomaticStravaUploadFlow(store: store, makeTCX: { _, _ in preconditionFailure("Status recovery exported TCX") }, prepareRequest: { _, _ in preconditionFailure("Status recovery prepared POST") }, preflight: { preconditionFailure("Status recovery ran preflight") }, submitRequest: { _ in preconditionFailure("Status recovery called upload POST") }, checkStatus: status, resolveWorkouts: resolve, now: { self.clock.date }, sleep: { await self.clock.sleep($0) })
        }
        func stop(_ flow: AutomaticStravaUploadFlow) { flow.setActive(false); clock.releaseAll() }
        func remove() { clock.releaseAll(); try? FileManager.default.removeItem(at: root) }
    }
}
