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

    func loadOrCreate(runID: UUID) throws -> PendingStravaUpload {
        if var record = try load(runID: runID) {
            let previous = record
            record.recoverAfterRelaunch()
            if record != previous { try save(record) }
            return record
        }
        let record = PendingStravaUpload(runID: runID)
        try save(record)
        return record
    }

    func save(_ record: PendingStravaUpload) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: fileURL(for: record.runID), options: .atomic)
    }

    private func fileURL(for runID: UUID) -> URL {
        directory.appendingPathComponent(runID.uuidString.lowercased() + ".json")
    }
}
