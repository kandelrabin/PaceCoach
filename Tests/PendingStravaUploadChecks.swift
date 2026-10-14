import Foundation

// Compile with StravaUploadAPI.swift and PendingStravaUpload.swift.
// Uses a temporary directory; no network or Health database is used.
@main
struct PendingStravaUploadChecks {
    private static var checks = 0
    private static let runID = UUID(uuidString: "12345678-ABCD-4321-ABCD-123456789ABC")!

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingStravaUploadStore(directory: root)
        var entry = try store.loadOrCreate(runID: runID)
        check(entry.phase == .pending && entry.isPostEligible, "new run pending")
        check(entry.runID == runID, "stable run identity")
        check(StravaUploadAPI.externalID(for: entry.runID) == "pacecoach-12345678-abcd-4321-abcd-123456789abc", "stable external ID")
        entry.preRequestFailed()
        check(entry.phase == .retryableFailure && entry.isPostEligible, "pre-request failure retries")
        try store.save(entry)
        entry = try store.loadOrCreate(runID: runID)
        check(entry.phase == .retryableFailure, "retryable failure survives reload")
        check(entry.beginSubmission() && !entry.isPostEligible, "submitting blocks duplicate")
        try store.save(entry)
        entry = try store.loadOrCreate(runID: runID)
        check(entry.phase == .outcomeUnknown && !entry.isPostEligible, "in-flight relaunch is unknown")
        check(!entry.beginSubmission(), "unknown cannot repost")

        let acceptedID = UUID()
        var accepted = try store.loadOrCreate(runID: acceptedID)
        check(accepted.beginSubmission(), "accepted run starts")
        accepted.receive(status("123", .accepted))
        try store.save(accepted)
        accepted = try store.loadOrCreate(runID: acceptedID)
        check(accepted.uploadID == "123" && accepted.canCheckStatus, "accepted ID survives reload")
        check(!accepted.isPostEligible && !accepted.beginSubmission(), "accepted never reposts")
        accepted.receive(status("999", .completed(activityID: 456)))
        check(accepted.uploadID == "123", "wrong status ID ignored")
        accepted.receive(status("123", .processing))
        check(accepted.phase == .processing(uploadID: "123"), "processing transition")
        accepted.receive(status("123", .completed(activityID: 456)))
        try store.save(accepted)
        accepted = try store.loadOrCreate(runID: acceptedID)
        check(accepted.phase == .completed(uploadID: "123", activityID: 456), "activity ID survives reload")
        check(!accepted.isPostEligible && !accepted.beginSubmission(), "completed never reposts")
        check(!accepted.canCheckStatus, "completed needs no status check")

        var rejected = PendingStravaUpload(runID: UUID())
        check(rejected.beginSubmission(), "rejection starts")
        rejected.rejected(duplicate: false)
        check(!rejected.isPostEligible, "4xx rejection terminal")
        var duplicate = PendingStravaUpload(runID: UUID())
        check(duplicate.beginSubmission(), "duplicate starts")
        duplicate.rejected(duplicate: true)
        check(!duplicate.isPostEligible, "duplicate terminal")
        var processingFailure = PendingStravaUpload(runID: UUID())
        check(processingFailure.beginSubmission(), "processing failure starts")
        processingFailure.receive(status("321", .failed(message: "Invalid TCX")))
        check(processingFailure.uploadID == "321" && !processingFailure.isPostEligible, "processing failure retains ID and blocks POST")

        let json = String(decoding: try Data(contentsOf: store.directory.appendingPathComponent(acceptedID.uuidString.lowercased() + ".json")), as: UTF8.self)
        check(!json.contains("accessToken") && !json.contains("refreshToken") && !json.contains("clientSecret") && !json.contains("Bearer "), "record contains no credentials")
        print("Pending Strava upload checks passed (\(checks) assertions)")
    }

    private static func status(_ id: String, _ state: StravaUploadStatus.State) -> StravaUploadStatus {
        StravaUploadStatus(uploadID: id, externalID: nil, statusText: nil, state: state)
    }

    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
}
