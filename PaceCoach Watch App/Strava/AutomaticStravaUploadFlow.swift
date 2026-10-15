import Foundation
import HealthKit
#if DEBUG
import os
#endif

/// One process-owned foreground queue and per-run ownership gate for End Run,
/// recovery, and manual controls. Known uploads use a separate GET operation;
/// the durable ledger remains authoritative for both operations.
@MainActor
final class AutomaticStravaUploadFlow {
    enum Trigger: String {
        case startup, activation, endRun, foregroundTimer, manual, explicit
    }

    #if DEBUG
    private let diagnosticID = UUID()
    private static let diagnosticLog = Logger(subsystem: "com.rabinkandel.PaceCoach", category: "StravaSubmission")
    #endif

    struct SubmissionResult {
        let record: PendingStravaUpload?
        let message: String
        let stopQueue: Bool
    }

    private let store: PendingStravaUploadStore?
    private let makeTCX: (HKWorkout, UUID) async throws -> URL
    private let prepareRequest: (URL, UUID) async throws -> URLRequest
    private let preflight: () async throws -> Void
    private let submitRequest: (URLRequest) async throws -> StravaUploadStatus
    private let checkStatus: ((String) async throws -> StravaStatusCheckResponse)?
    private let resolveWorkouts: ([UUID]) async throws -> [HKWorkout]
    private let acceptedSources: Set<String>
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var recovered = false
    private var knownWorkouts: [UUID: HKWorkout] = [:]
    private var inFlightRunIDs = Set<UUID>()
    private var statusRequestInFlight = false
    private var drainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = UUID()
    private var rescanRequested = false
    private var notBefore: Date?
    private var statusNotBefore: Date?
    private var backoffStep = 0
    private(set) var isActive: Bool
    private(set) var scheduledRetryDelay: TimeInterval?

    init(
        store: PendingStravaUploadStore?,
        makeTCX: @escaping (HKWorkout, UUID) async throws -> URL,
        prepareRequest: @escaping (URL, UUID) async throws -> URLRequest,
        preflight: @escaping () async throws -> Void,
        submitRequest: @escaping (URLRequest) async throws -> StravaUploadStatus,
        checkStatus: ((String) async throws -> StravaStatusCheckResponse)? = nil,
        resolveWorkouts: @escaping ([UUID]) async throws -> [HKWorkout] = { _ in [] },
        acceptedSources: Set<String>? = nil,
        initiallyActive: Bool = true,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.store = store
        self.makeTCX = makeTCX
        self.prepareRequest = prepareRequest
        self.preflight = preflight
        self.submitRequest = submitRequest
        self.checkStatus = checkStatus
        self.resolveWorkouts = resolveWorkouts
        self.acceptedSources = acceptedSources ?? PaceCoachSavedRunSelection.acceptedSourceBundleIDs
        self.isActive = initiallyActive
        self.now = now
        self.sleep = sleep
        trace("coordinator-created", trigger: .startup)
        // The live singleton is initialized before any submission can start.
        recoverIfNeeded()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        cancelRetry()
        notBefore = nil
        trace(active ? "active" : "inactive", trigger: .activation)
        if active { requestRetry(trigger: .activation) }
        // A dispatched POST may still return a result worth persisting. Stop
        // future dispatches, rather than cancelling and losing that response.
    }

    /// Registration stays synchronous and precedes export/network work.
    @discardableResult
    func registerAndStart(savedWorkout: HKWorkout, runID: UUID) -> Task<Void, Never>? {
        trace("registration-requested", trigger: .endRun, runID: runID, workoutID: savedWorkout.uuid)
        guard recovered, PaceCoachSavedRunSelection.exact(
            runID: runID, in: [savedWorkout], acceptedSourceBundleIDs: acceptedSources
        ) != nil,
              let store, !inFlightRunIDs.contains(runID) else { return nil }
        do {
            let existing = try store.load(runID: runID)
            trace("registration-ledger", trigger: .endRun, runID: runID, record: existing)
            let registered = try store.loadOrCreate(runID: runID, workoutStartDate: savedWorkout.startDate)
            guard registered.isPostEligible else { return nil }
            guard knownWorkouts[runID] == nil else { return nil }
            knownWorkouts[runID] = savedWorkout
            if existing == nil {
                notBefore = nil
                rescanRequested = true
            }
            trace("registered", trigger: .endRun, runID: runID, record: registered)
            return requestRetry(trigger: .endRun)
        } catch { return nil }
    }

    /// Overlapping lifecycle/timer triggers share the same drain task.
    @discardableResult
    func requestRetry(trigger: Trigger = .explicit) -> Task<Void, Never>? {
        trace("retry-trigger", trigger: trigger)
        guard isActive else {
            trace("trigger-inactive", trigger: trigger)
            return nil
        }
        recoverIfNeeded()
        guard recovered else { return nil }
        if let drainTask {
            trace("drain-coalesced", trigger: trigger)
            return drainTask
        }
        let postCoolingDown = notBefore.map { now() < $0 } ?? false
        let onlyStatusWork = retryTask != nil && (try? store?.eligibleRecords().isEmpty) == true
        if (postCoolingDown || onlyStatusWork), !hasDueStatusChecks() {
            trace("trigger-cooldown", trigger: trigger)
            return nil
        }
        cancelRetry()
        trace("drain-created", trigger: trigger)
        let task = Task(priority: .utility) { [self] in
            repeat {
                rescanRequested = false
                var stop = await drainOnce(trigger: trigger)
                if !stop { stop = await drainStatusChecks(trigger: trigger) }
                if stop { break }
            } while isActive && rescanRequested
            drainTask = nil
            trace("drain-finished", trigger: trigger)
            scheduleRetryIfNeeded()
        }
        drainTask = task
        return task
    }

    func submitManually(runID: UUID, tcxFile: URL) async -> SubmissionResult {
        let result = await attempt(runID: runID, workout: nil, file: tcxFile, trigger: .manual)
        if drainTask == nil { scheduleRetryIfNeeded() }
        return result
    }

    /// Uses the same durable-state/ownership checks as automatic reconciliation.
    /// A stale development view can neither regress a terminal record nor POST.
    func reconcileManually(runID: UUID) async -> SubmissionResult {
        let result = await reconcile(runID: runID, trigger: .manual, ownsBatch: false)
        if drainTask == nil { scheduleRetryIfNeeded() }
        return result
    }

    private func recoverIfNeeded() {
        guard !recovered, let store else { return }
        do {
            #if DEBUG
            for record in (try? store.records()) ?? [] {
                trace("startup-ledger", trigger: .startup, runID: record.runID, record: record)
            }
            #endif
            try store.recoverInterruptedSubmissions()
            recovered = true
            trace("startup-recovery-complete", trigger: .startup)
        } catch { } // Fail closed until startup recovery can be persisted.
    }

    private func drainOnce(trigger: Trigger) async -> Bool {
        guard isActive, let store else { return true }
        if let notBefore, now() < notBefore { return false }
        let records: [PendingStravaUpload]
        let resolved: [HKWorkout]
        do {
            records = try store.eligibleRecords()
            guard !records.isEmpty else { return false }
        } catch { return true }
        // Consume the POST opportunity here, never when a status GET happens
        // to finish after the POST deadline. Each queue owns its own backoff.
        notBefore = nil
        do {
            let missing = records.map(\.runID).filter { knownWorkouts[$0] == nil }
            resolved = missing.isEmpty ? [] : try await resolveWorkouts(missing)
        } catch {
            // Protected/unavailable Health data affects export, not known-ID GETs.
            return false
        }
        guard isActive else { return true }

        var queue: [(UUID, HKWorkout)] = []
        for record in records {
            trace("queue-eligible", trigger: trigger, runID: record.runID, record: record)
            if let workout = knownWorkouts[record.runID] ?? PaceCoachSavedRunSelection.exact(
                runID: record.runID, in: resolved, acceptedSourceBundleIDs: acceptedSources
            ) {
                queue.append((record.runID, workout))
                trace("workout-resolved", trigger: trigger, runID: record.runID, workoutID: workout.uuid)
            }
            // Unavailable Health data leaves the durable entry eligible.
        }
        queue.sort {
            if $0.1.startDate != $1.1.startDate { return $0.1.startDate < $1.1.startDate }
            return $0.0.uuidString < $1.0.uuidString
        }
        for (runID, workout) in queue {
            guard isActive else { return true }
            let result = await attempt(runID: runID, workout: workout, file: nil, trigger: trigger)
            knownWorkouts.removeValue(forKey: runID)
            if result.stopQueue { return true }
        }
        return false
    }

    private func attempt(runID: UUID, workout: HKWorkout?, file: URL?, trigger: Trigger) async -> SubmissionResult {
        guard recovered, isActive, let store, !inFlightRunIDs.contains(runID) else {
            trace(inFlightRunIDs.contains(runID) ? "claim-rejected-owned" : "claim-rejected-unavailable",
                  trigger: trigger, runID: runID)
            return SubmissionResult(record: nil, message: "An upload is already running or PaceCoach is inactive.", stopQueue: false)
        }
        // Claim before the first await; MainActor isolation alone is reentrant.
        inFlightRunIDs.insert(runID)
        trace("claim-acquired", trigger: trigger, runID: runID)
        defer {
            inFlightRunIDs.remove(runID)
            trace("claim-released", trigger: trigger, runID: runID)
        }
        do {
            let record = try store.load(runID: runID)
            trace("claimed-ledger", trigger: trigger, runID: runID, record: record)
            guard record?.isPostEligible == true else {
                trace("attempt-suppressed-state", trigger: trigger, runID: runID, record: record)
                return SubmissionResult(record: nil, message: "Upload state changed. Find the saved run again.", stopQueue: false)
            }
        } catch {
            trace("ledger-read-failed", trigger: trigger, runID: runID)
            return SubmissionResult(record: nil, message: "Could not read upload state. No POST was sent.", stopQueue: true)
        }

        let tcxFile: URL
        do {
            if let file { tcxFile = file }
            else if let workout { tcxFile = try await makeTCX(workout, runID) }
            else { throw StravaUploadError.invalidResponse }
        } catch {
            trace("pre-request-export-failed", trigger: trigger, runID: runID)
            return preRequestFailed(runID: runID, stopQueue: false)
        }
        let request: URLRequest
        do {
            guard isActive, !Task.isCancelled else { return inactiveResult() }
            request = try await prepareRequest(tcxFile, runID)
            guard isActive, !Task.isCancelled else { return inactiveResult() }
            try await preflight()
        } catch {
            trace("pre-request-prepare-or-probe-failed", trigger: trigger, runID: runID)
            return preRequestFailed(runID: runID, stopQueue: true)
        }
        guard isActive, !Task.isCancelled else { return inactiveResult() }

        var current: PendingStravaUpload
        do {
            let latest = try store.load(runID: runID)
            trace("handoff-ledger", trigger: trigger, runID: runID, record: latest)
            guard let latest, latest.isPostEligible else {
                trace("post-suppressed-state", trigger: trigger, runID: runID, record: latest)
                return SubmissionResult(record: nil, message: "Upload state changed. Find the saved run again.", stopQueue: false)
            }
            current = latest
            guard current.beginSubmission() else { return inactiveResult() }
            try store.save(current)
            trace("submitting-persisted", trigger: trigger, runID: runID, record: current)
        } catch {
            return SubmissionResult(record: nil, message: "Could not save upload state. No POST was sent.", stopQueue: true)
        }

        var stopQueue = false
        do {
            trace("post-dispatch", trigger: trigger, runID: runID, record: current)
            let status = try await submitRequest(request)
            current.receive(status)
            current.deferInitialStatusCheck(at: now())
            trace("post-response", trigger: trigger, runID: runID, record: current, response: status)
        } catch {
            switch error as? StravaUploadError {
            case .duplicate: current.rejected(duplicate: true)
            case .httpStatus(let code) where code >= 400 && code < 500:
                current.rejected(duplicate: false)
                stopQueue = code == 401 || code == 403
            default:
                current.postOutcomeUnknown()
                stopQueue = true
            }
            trace("post-failed", trigger: trigger, runID: runID, record: current)
        }
        do {
            try store.save(current)
            trace("result-persisted", trigger: trigger, runID: runID, record: current)
            let message = current.phase == .outcomeUnknown
                ? "Outcome unknown: the request may have reached Strava. Do not submit again."
                : "Strava response saved. Processing status will be checked while PaceCoach is active."
            return SubmissionResult(record: current, message: message, stopQueue: stopQueue)
        } catch {
            trace("result-persist-failed", trigger: trigger, runID: runID, record: current)
            return SubmissionResult(record: current, message: "Could not save Strava's result. Do not submit again.", stopQueue: true)
        }
    }

    private func preRequestFailed(runID: UUID, stopQueue: Bool) -> SubmissionResult {
        do {
            guard let store, var current = try store.load(runID: runID), current.isPostEligible else {
                return inactiveResult()
            }
            current.preRequestFailed()
            try store.save(current)
            return SubmissionResult(record: current, message: "Request preparation failed before POST. Retry is safe.", stopQueue: stopQueue)
        } catch {
            return SubmissionResult(record: nil, message: "Could not save upload state. No POST was sent.", stopQueue: true)
        }
    }

    private func inactiveResult() -> SubmissionResult {
        SubmissionResult(record: nil, message: "Upload deferred; no POST was sent.", stopQueue: false)
    }

    private func statusDeadline() throws -> Date? {
        guard checkStatus != nil, let store else { return nil }
        let records = try store.records().filter(\.canCheckStatus)
        guard !records.isEmpty else { return nil }
        let shared = try sharedStatusDeadline()
        return records.map { max($0.nextStatusCheckAt ?? now(), shared) }.min()
    }

    private func sharedStatusDeadline() throws -> Date {
        max(try store?.statusNotBefore() ?? .distantPast, statusNotBefore ?? .distantPast)
    }

    private func deferStatusChecks(until deadline: Date) throws {
        // A storage failure must not cause a one-second retry loop against the
        // same unwritable file. Preserve pacing in this process even if the
        // durable policy cannot be updated; dispatch still fails closed.
        statusNotBefore = max(statusNotBefore ?? .distantPast, deadline)
        try store?.deferStatusChecks(until: deadline)
    }

    private func hasDueStatusChecks() -> Bool {
        guard let deadline = try? statusDeadline() else { return false }
        return deadline <= now()
    }

    private func drainStatusChecks(trigger: Trigger) async -> Bool {
        guard isActive, checkStatus != nil, let store, !statusRequestInFlight else { return false }
        do {
            guard try sharedStatusDeadline() <= now() else { return false }
            let due = try store.records().filter {
                $0.canCheckStatus && ($0.nextStatusCheckAt ?? .distantPast) <= now()
            }.sorted {
                // Least-recent attempt prevents an old processing/error record
                // from starving unattempted records in a bounded batch.
                if $0.lastStatusAttemptAt != $1.lastStatusAttemptAt {
                    return ($0.lastStatusAttemptAt ?? .distantPast) < ($1.lastStatusAttemptAt ?? .distantPast)
                }
                if $0.workoutStartDate != $1.workoutStartDate {
                    return ($0.workoutStartDate ?? .distantPast) < ($1.workoutStartDate ?? .distantPast)
                }
                return $0.runID.uuidString < $1.runID.uuidString
            }
            for record in due.prefix(3) {
                guard isActive else { return true }
                let result = await reconcile(runID: record.runID, trigger: trigger, ownsBatch: true)
                if result.stopQueue { return true }
            }
            return false
        } catch {
            trace("status-policy-or-ledger-failed", trigger: trigger)
            return true
        }
    }

    /// This operation has no path to export, preflight, prepare, or submit.
    /// Persist attempt timing before GET, then reread after its suspension point.
    private func reconcile(runID: UUID, trigger: Trigger, ownsBatch: Bool) async -> SubmissionResult {
        let latest = try? store?.load(runID: runID)
        guard recovered, isActive, let store, let checkStatus,
              !inFlightRunIDs.contains(runID), !statusRequestInFlight else {
            return SubmissionResult(record: latest, message: "Status check deferred or already running.", stopQueue: false)
        }
        inFlightRunIDs.insert(runID)
        statusRequestInFlight = true
        defer {
            inFlightRunIDs.remove(runID)
            statusRequestInFlight = false
        }
        do {
            guard var current = try store.load(runID: runID), current.canCheckStatus,
                  let uploadID = current.uploadID else {
                return SubmissionResult(record: latest, message: "Saved status needs no processing check.", stopQueue: false)
            }
            let sharedDeadline = try sharedStatusDeadline()
            guard ownsBatch || sharedDeadline <= now(),
                  current.beginStatusCheck(at: now()) else {
                return SubmissionResult(record: current, message: "Status check deferred until a later foreground opportunity.", stopQueue: false)
            }
            try store.save(current)
            // One bounded batch per 30 seconds, including manual checks. A
            // relaunch cannot skip pacing by selecting another persisted run.
            try deferStatusChecks(until: now().addingTimeInterval(30))
            trace("status-get-dispatch", trigger: trigger, runID: runID, record: current)
            let response = try await checkStatus(uploadID)
            guard response.status.uploadID == uploadID else { throw StravaUploadError.invalidResponse }
            guard var updated = try store.load(runID: runID) else { throw PendingStravaUploadStore.StoreError.invalidRecord }
            // Do not overwrite a terminal result or a different upload identity.
            if updated.canCheckStatus && updated.uploadID == uploadID {
                updated.receive(response.status)
                try store.save(updated)
            }
            trace("status-result-persisted", trigger: trigger, runID: runID, record: updated, response: response.status)
            if let deadline = response.retryNotBefore, deadline > now() {
                try deferStatusChecks(until: deadline)
                return SubmissionResult(record: updated, message: "Strava status saved; further checks are deferred by its rate limit.", stopQueue: true)
            }
            return SubmissionResult(record: updated, message: "Strava status updated.", stopQueue: false)
        } catch {
            let sharedDelay: TimeInterval?
            switch error as? StravaUploadError {
            case .statusDeferred(let deadline): sharedDelay = max(30, deadline.timeIntervalSince(now()))
            case .network: sharedDelay = 60
            case .httpStatus(let code) where code == 401 || code == 403: sharedDelay = 300
            case .httpStatus(let code) where code == 429 || code >= 500: sharedDelay = 300
            case .invalidResponse, .duplicate, .httpStatus: sharedDelay = nil
            default: sharedDelay = 60 // Includes token refresh, protected Keychain, and persistence failures.
            }
            if let sharedDelay { try? deferStatusChecks(until: now().addingTimeInterval(sharedDelay)) }
            let record = try? store.load(runID: runID)
            trace("status-get-deferred", trigger: trigger, runID: runID, record: record)
            return SubmissionResult(record: record,
                                    message: "Could not save or check Strava status. Check later; no TCX was reposted.",
                                    stopQueue: sharedDelay != nil)
        }
    }

    private func cancelRetry() {
        retryGeneration = UUID()
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryDelay = nil
    }

    private func scheduleRetryIfNeeded() {
        guard isActive, let store else {
            cancelRetry()
            return
        }
        var deadlines: [Date] = []
        if (try? store.eligibleRecords().isEmpty) == false {
            if notBefore == nil {
                let delays: [TimeInterval] = [30, 60, 120, 300]
                notBefore = now().addingTimeInterval(delays[min(backoffStep, delays.count - 1)])
                backoffStep = min(backoffStep + 1, delays.count - 1)
            }
            deadlines.append(notBefore!)
        } else {
            notBefore = nil
            backoffStep = 0
        }
        do {
            // A manual GET schedules again after releasing ownership. Do not
            // re-arm an overdue status timer every second while it is awaited.
            if !statusRequestInFlight, let deadline = try statusDeadline() { deadlines.append(deadline) }
        } catch {
            // Unreadable policy fails closed; do not spin trying to repair it.
            deadlines.append(now().addingTimeInterval(300))
        }
        guard let deadline = deadlines.min() else { cancelRetry(); return }
        let delay = max(1, deadline.timeIntervalSince(now()))
        cancelRetry()
        scheduledRetryDelay = delay
        let generation = retryGeneration
        let sleep = self.sleep
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.isActive,
                  self.retryGeneration == generation else { return }
            self.retryTask = nil
            self.scheduledRetryDelay = nil
            self.requestRetry(trigger: .foregroundTimer)
        }
    }

    /// Log only identities and phase tags, never requests, error text, or workout data.
    private func trace(_ event: String, trigger: Trigger, runID: UUID? = nil,
                       record: PendingStravaUpload? = nil, workoutID: UUID? = nil,
                       response: StravaUploadStatus? = nil) {
        #if DEBUG
        let phase: String
        switch record?.phase {
        case .pending: phase = "pending"
        case .retryableFailure: phase = "retryableFailure"
        case .submitting: phase = "submitting"
        case .accepted: phase = "accepted"
        case .processing: phase = "processing"
        case .completed: phase = "completed"
        case .failed: phase = "failed"
        case .duplicate: phase = "duplicate"
        case .outcomeUnknown: phase = "outcomeUnknown"
        case nil: phase = "none"
        }
        let activityID: String
        if case .completed(_, let id) = record?.phase { activityID = String(id) }
        else { activityID = "none" }
        let externalID = runID.map { StravaUploadAPI.externalID(for: $0) } ?? "none"
        // Accept only our UUID-shaped identifier; never log arbitrary server text.
        let returnedID = response?.externalID ?? ""
        let responseRunID: String
        if returnedID.hasPrefix("pacecoach-"),
           let uuid = UUID(uuidString: String(returnedID.dropFirst("pacecoach-".count).prefix(36))),
           returnedID == StravaUploadAPI.externalID(for: uuid) || returnedID == StravaUploadAPI.externalID(for: uuid) + ".tcx" {
            responseRunID = uuid.uuidString
        } else { responseRunID = "unrecognized-or-absent" }
        let message = "event=\(event) pid=\(ProcessInfo.processInfo.processIdentifier) coordinator=\(diagnosticID) trigger=\(trigger.rawValue) run=\(runID?.uuidString ?? "none") workout=\(workoutID?.uuidString ?? "none") phase=\(phase) external=\(externalID) responseRun=\(responseRunID) upload=\(record?.uploadID ?? "none") activity=\(activityID)"
        Self.diagnosticLog.notice("\(message, privacy: .public)")
        #endif
    }
}
