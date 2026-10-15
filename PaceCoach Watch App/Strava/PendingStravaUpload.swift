import Foundation

/// Non-secret upload ledger entry. HealthKit retains the workout and sensor data.
struct PendingStravaUpload: Codable, Equatable {
    enum Phase: Codable, Equatable {
        case pending
        case submitting
        case retryableFailure
        case accepted(uploadID: String)
        case processing(uploadID: String)
        case completed(uploadID: String, activityID: Int64)
        case failed(uploadID: String?)
        case duplicate(uploadID: String?)
        case outcomeUnknown
    }

    let runID: UUID
    private(set) var phase: Phase = .pending
    // Optional so Milestone 1 records decode unchanged. Legacy UUID order is a
    // deterministic fallback, not evidence of workout chronology.
    private(set) var workoutStartDate: Date?
    private(set) var lastStatusAttemptAt: Date?
    private(set) var nextStatusCheckAt: Date?
    private(set) var statusBackoffStep: Int?

    init(runID: UUID, workoutStartDate: Date? = nil) {
        self.runID = runID
        self.workoutStartDate = workoutStartDate
    }

    var uploadID: String? {
        switch phase {
        case .accepted(let id), .processing(let id), .completed(let id, _): return id
        case .failed(let id), .duplicate(let id): return id
        default: return nil
        }
    }

    /// Automatic policy: only a never-submitted run or a proven pre-request failure.
    var isPostEligible: Bool {
        phase == .pending || phase == .retryableFailure
    }

    var canCheckStatus: Bool {
        switch phase {
        case .accepted, .processing: return true
        default: return false
        }
    }

    mutating func deferInitialStatusCheck(at date: Date) {
        guard canCheckStatus, nextStatusCheckAt == nil else { return }
        nextStatusCheckAt = date.addingTimeInterval(30)
    }

    /// Persist this before GET. An interrupted GET remains safe to repeat, but
    /// relaunch must not reset its polling budget or turn it into another POST.
    mutating func beginStatusCheck(at date: Date) -> Bool {
        guard canCheckStatus, nextStatusCheckAt.map({ $0 <= date }) ?? true else { return false }
        let delays: [TimeInterval] = [30, 60, 120, 300, 900, 3600]
        let step = min(max(statusBackoffStep ?? 0, 0), delays.count - 1)
        lastStatusAttemptAt = date
        nextStatusCheckAt = date.addingTimeInterval(delays[step])
        statusBackoffStep = min(step + 1, delays.count - 1)
        return true
    }

    mutating func beginSubmission() -> Bool {
        guard isPostEligible else { return false }
        phase = .submitting
        return true
    }

    mutating func preRequestFailed() {
        guard phase == .pending || phase == .retryableFailure else { return }
        phase = .retryableFailure
    }

    mutating func postOutcomeUnknown() {
        guard phase == .submitting else { return }
        phase = .outcomeUnknown
    }

    mutating func rejected(duplicate: Bool) {
        guard phase == .submitting else { return }
        phase = duplicate ? .duplicate(uploadID: nil) : .failed(uploadID: nil)
    }

    mutating func receive(_ status: StravaUploadStatus) {
        guard phase == .submitting || (canCheckStatus && uploadID == status.uploadID) else { return }
        switch status.state {
        case .accepted: phase = .accepted(uploadID: status.uploadID)
        case .processing: phase = .processing(uploadID: status.uploadID)
        case .completed(let activityID): phase = .completed(uploadID: status.uploadID, activityID: activityID)
        case .failed: phase = .failed(uploadID: status.uploadID)
        case .duplicate: phase = .duplicate(uploadID: status.uploadID)
        }
    }

    /// A persisted in-flight POST cannot be distinguished from one accepted by Strava.
    mutating func recoverAfterRelaunch() {
        if phase == .submitting { phase = .outcomeUnknown }
    }
}

/// One atomic JSON file per run avoids rewriting unrelated records. A read or
/// write error fails closed: callers must not infer a fresh pending upload.
struct PendingStravaUploadStore {
    enum StoreError: Error { case documentsUnavailable, invalidRecord }

    let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, directory: URL? = nil) throws {
        guard let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsUnavailable
        }
        self.directory = root.appendingPathComponent("StravaUploads", isDirectory: true)
        self.fileManager = fileManager
    }

    func load(runID: UUID) throws -> PendingStravaUpload? {
        let path = fileURL(for: runID)
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        let record = try JSONDecoder().decode(PendingStravaUpload.self, from: Data(contentsOf: path))
        guard record.runID == runID else { throw StoreError.invalidRecord }
        return record
    }

    func loadOrCreate(runID: UUID, workoutStartDate: Date? = nil) throws -> PendingStravaUpload {
        if let record = try load(runID: runID) { return record }
        let record = PendingStravaUpload(runID: runID, workoutStartDate: workoutStartDate)
        try save(record)
        return record
    }

    /// Ordinary reads never recover a submission still owned by this process.
    func records() throws -> [PendingStravaUpload] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url -> PendingStravaUpload? in
                guard url.pathExtension == "json",
                      let runID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      url.lastPathComponent == runID.uuidString.lowercased() + ".json" else { return nil }
                // Preserve corrupt/unreadable files and exclude them from POST.
                return try? load(runID: runID)
            }
            .sorted { $0.runID.uuidString < $1.runID.uuidString }
    }

    func eligibleRecords() throws -> [PendingStravaUpload] {
        try records().filter(\.isPostEligible)
    }

    /// Call at process startup, before any submitter can own an in-flight POST.
    func recoverInterruptedSubmissions() throws {
        for var record in try records() where record.phase == .submitting {
            record.recoverAfterRelaunch()
            try save(record)
        }
    }

    func save(_ record: PendingStravaUpload) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: fileURL(for: record.runID), options: .atomic)
    }

    /// Separate non-secret policy file: shared status pacing/rate limits must
    /// survive scene changes and relaunch, including across different runs.
    func statusNotBefore() throws -> Date? {
        let url = directory.appendingPathComponent("status-policy.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(StatusPolicy.self, from: Data(contentsOf: url)).notBefore
    }

    func deferStatusChecks(until date: Date) throws {
        let deadline = max(try statusNotBefore() ?? .distantPast, date)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(StatusPolicy(notBefore: deadline))
            .write(to: directory.appendingPathComponent("status-policy.json"), options: .atomic)
    }

    private struct StatusPolicy: Codable { let notBefore: Date }

    private func fileURL(for runID: UUID) -> URL {
        directory.appendingPathComponent(runID.uuidString.lowercased() + ".json")
    }
}
