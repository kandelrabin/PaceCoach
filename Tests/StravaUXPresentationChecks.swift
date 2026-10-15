import Foundation

// Compile with StravaUploadAPI.swift, PendingStravaUpload.swift, and
// StravaStatusPresentation.swift. Deliberately links no HealthKit, token service,
// upload coordinator, or network transport. All files are temporary fixtures.
@main
struct StravaUXPresentationChecks {
    private static var checks = 0
    private typealias Presentation = StravaStatusPresentation
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func main() throws {
        try emptyAndCredentials()
        try everyPersistedPhase()
        try olderUnresolvedAndLegacyDates()
        try recentUploadIsCompact()
        try corruptAndUnavailableState()
        try readsHaveNoSideEffects()
        print("Strava UX presentation checks passed (\(checks) assertions)")
    }

    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    private static func emptyAndCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.read(credentials: .notSetUp)
        check(missing.summary == .setupRequired, "missing credentials request iPhone setup")
        check(missing.summary.title == "Set up Strava on iPhone", "setup wording")
        check(missing.runs.isEmpty && !missing.isUploadStatusUnavailable, "missing ledger is genuinely empty")
        check(!FileManager.default.fileExists(atPath: fixture.root.path), "reading fresh install creates no directory")
        let ready = fixture.read()
        check(ready.summary == .noUploads, "set up with no uploads")
        check(ready.homeSubtitle == "Uploads automatically", "empty home state explains automatic path")
        check(fixture.read(credentials: .unavailable).summary == .unavailable, "credential read failure is not disconnected or success")
        let noStore = StravaStatusReader(store: nil, readCredentials: { .setUp }).read()
        check(noStore.isUploadStatusUnavailable && noStore.summary == .unavailable, "unavailable store is not empty")

        let unknown = record(1, phase: .outcomeUnknown)
        try fixture.store.save(unknown)
        let needsSetup = fixture.read(credentials: .notSetUp)
        check(needsSetup.summary == .setupRequired, "missing credentials still request setup")
        check(needsSetup.attentionRuns.map(\.id) == [unknown.runID], "setup must not hide unconfirmed uploads")
    }

    private static func everyPersistedPhase() throws {
        let phases: [(PendingStravaUpload.Phase, Presentation.Status, String)] = [
            (.pending, .waiting, "Waiting to upload"),
            (.retryableFailure, .waiting, "Waiting to upload"),
            (.submitting, .uploading, "Uploading to Strava…"),
            (.accepted(uploadID: "1"), .processing, "Sent to Strava · Processing"),
            (.processing(uploadID: "1"), .processing, "Sent to Strava · Processing"),
            (.completed(uploadID: "1", activityID: 2), .uploaded, "Uploaded to Strava"),
            (.duplicate(uploadID: "1"), .duplicate, "Strava reported a duplicate"),
            (.failed(uploadID: "1"), .failed, "Upload failed"),
            (.outcomeUnknown, .unconfirmed, "Upload unconfirmed")
        ]
        for (phase, expected, title) in phases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let entry = record(1, phase: phase, at: date)
            try fixture.store.save(entry)
            let view = fixture.read()
            check(view.summary == expected, "persisted \(phase) summary")
            check(view.runs.first?.status == expected, "persisted \(phase) row")
            check(view.summary.title == title, "persisted \(phase) copy")
            check(view.runs.first?.date == date, "actual workout date retained")
            check(try fixture.store.load(runID: entry.runID) == entry, "presentation preserves exact durable phase")
        }
        check(!(Presentation.Status.waiting.explanation ?? "").lowercased().contains("offline"), "retryable does not diagnose offline")
        check(!(Presentation.Status.failed.explanation ?? "").lowercased().contains("authentication failed"), "failed does not diagnose authentication")
        let unknownCopy = Presentation.Status.unconfirmed.explanation ?? ""
        check(unknownCopy.contains("May already be on Strava"), "unconfirmed warns activity may exist")
        check(unknownCopy.contains("PaceCoach won’t resend it automatically"), "unconfirmed explains no automatic repost")
    }

    private static func olderUnresolvedAndLegacyDates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let olderPhases: [PendingStravaUpload.Phase] = [
            .pending, .retryableFailure, .submitting, .accepted(uploadID: "1"),
            .processing(uploadID: "1"), .failed(uploadID: nil),
            .duplicate(uploadID: nil), .outcomeUnknown
        ]
        for (index, phase) in olderPhases.enumerated() {
            try fixture.store.save(record(index + 1, phase: phase, at: date.addingTimeInterval(Double(index))))
        }
        let latest = record(20, phase: .completed(uploadID: "2", activityID: 3), at: date + 100)
        try fixture.store.save(latest)
        let view = fixture.read()
        check(view.summary == .unconfirmed, "new success cannot hide old unconfirmed summary")
        check(view.attentionRuns.count == olderPhases.count, "all unresolved and action-worthy runs remain under Needs attention")
        check(view.homeSubtitle == "Upload unconfirmed", "home keeps unconfirmed status despite newer success")
        check(view.recentUpload?.id == latest.runID, "new success remains inspectable separately")
        check(view.runs.first?.id == latest.runID, "real dates establish newest order")

        let legacy = record(30, phase: .outcomeUnknown)
        try fixture.store.save(legacy)
        let legacySuccess = record(31, phase: .completed(uploadID: "3", activityID: 4))
        try fixture.store.save(legacySuccess)
        // Remove the optional key entirely, matching old on-disk records.
        let path = fixture.path(legacy.runID)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        json.removeValue(forKey: "workoutStartDate")
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let withLegacy = fixture.read()
        check(withLegacy.runs.first(where: { $0.id == legacy.runID })?.date == nil, "legacy missing date stays missing")
        check(withLegacy.attentionRuns.contains(where: { $0.id == legacy.runID }), "undated unknown remains visible")
        check(withLegacy.runs.contains(where: { $0.id == legacySuccess.runID && $0.date == nil }), "undated success retains missing date in snapshot")
        check(withLegacy.recentUpload?.id == latest.runID, "undated success cannot become recent upload")
        check(withLegacy.runs.first?.id == latest.runID, "UUID never substitutes for chronology")

        for phase in olderPhases {
            let mixed = Presentation(credentials: .setUp, snapshot: .init(records: [latest, record(50, phase: phase)], isUnavailable: false))
            check(mixed.summary != .uploaded, "each older unresolved phase outranks newer success")
            check(mixed.attentionRuns.contains(where: { $0.id == id(50) }), "each unresolved phase remains under Needs attention")
        }
    }

    private static func recentUploadIsCompact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for value in [1, 2] {
            try fixture.store.save(record(value, phase: .completed(uploadID: "1", activityID: 2)))
        }
        let legacyOnly = fixture.read()
        check(legacyOnly.recentUpload == nil, "undated success history does not form a recent section")
        check(legacyOnly.attentionRuns.isEmpty, "successful legacy runs need no attention cards")
        check(legacyOnly.runs.count == 2, "hidden historical successes are retained in read-only snapshot")

        let older = record(3, phase: .completed(uploadID: "2", activityID: 3), at: date)
        let newer = record(4, phase: .completed(uploadID: "3", activityID: 4), at: date + 100)
        try fixture.store.save(older)
        try fixture.store.save(newer)
        let dated = fixture.read()
        check(dated.recentUpload?.id == newer.runID, "only newest dated success is recent upload")
        check(dated.recentUpload?.date == date + 100, "recent date is the persisted workout date")
        check(dated.attentionRuns.isEmpty, "successful history does not lengthen attention section")
        check(dated.runs.count == 4, "display compaction never removes persisted records")

        let unknown = record(5, phase: .outcomeUnknown)
        try fixture.store.save(unknown)
        let unresolved = fixture.read()
        check(unresolved.homeSubtitle == "Upload unconfirmed", "new successful uploads cannot hide legacy unknown home status")
        check(unresolved.attentionRuns.map(\.id) == [unknown.runID], "undated unknown stays visible while successes compact")
        check(unresolved.attentionRuns.first?.date == nil, "legacy attention row keeps Date unavailable")
        check(unresolved.recentUpload?.id == newer.runID, "recent success remains separate from attention")
    }

    private static func corruptAndUnavailableState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.store.directory, withIntermediateDirectories: true)
        let corrupt = fixture.path(id(1))
        try Data("invalid JSON".utf8).write(to: corrupt)
        check(fixture.read().summary == .unavailable, "corrupt persisted state is unavailable")
        check(fixture.read().summary.title == "Upload status unavailable", "unavailable wording")
        check(fixture.read().runs.isEmpty, "corrupt state not invented as a run")
        let success = record(2, phase: .completed(uploadID: "1", activityID: 2), at: date)
        try fixture.store.save(success)
        check(fixture.read().summary == .unavailable, "readable success cannot mask corrupt record")
        check(fixture.read().recentUpload?.id == success.runID, "readable recent success retained alongside unavailable warning")
        try FileManager.default.removeItem(at: corrupt)
        try JSONEncoder().encode(record(3, phase: .pending)).write(to: corrupt)
        check(fixture.read().isUploadStatusUnavailable, "mismatched filename and record ID rejected")
        try FileManager.default.removeItem(at: corrupt)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        check(fixture.read().isUploadStatusUnavailable, "unreadable record path rejected")
        try FileManager.default.removeItem(at: corrupt)
        let invalidName = fixture.store.directory.appendingPathComponent("broken-record.json")
        try Data("{}".utf8).write(to: invalidName)
        check(fixture.read().isUploadStatusUnavailable, "noncanonical record filename not silently hidden")
        try FileManager.default.removeItem(at: invalidName)
        let uppercaseName = fixture.store.directory.appendingPathComponent("ABCDEF00-0000-0000-0000-000000000001.json")
        try Data("{}".utf8).write(to: uppercaseName)
        check(fixture.read().isUploadStatusUnavailable, "noncanonical uppercase filename reported")
        try FileManager.default.removeItem(at: uppercaseName)

        try fixture.store.deferStatusChecks(until: date)
        check(!fixture.read().isUploadStatusUnavailable && fixture.read().runs.count == 1, "healthy policy is not a run or corruption")
        let policy = fixture.store.directory.appendingPathComponent("status-policy.json")
        try Data("invalid policy".utf8).write(to: policy)
        check(fixture.read().isUploadStatusUnavailable, "corrupt status policy is visible")

        let unavailable = try Fixture()
        defer { unavailable.remove() }
        try FileManager.default.createDirectory(at: unavailable.root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: unavailable.store.directory)
        check(unavailable.read().isUploadStatusUnavailable, "ledger path is a file")
        let deniedStore = try PendingStravaUploadStore(fileManager: DeniedEnumeration(), directory: fixture.root)
        check(deniedStore.presentationSnapshot().isUnavailable, "directory permission error not treated as empty")
    }

    private static func readsHaveNoSideEffects() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let entries = [record(1, phase: .pending), record(2, phase: .submitting), record(3, phase: .outcomeUnknown)]
        for entry in entries { try fixture.store.save(entry) }
        try fixture.store.deferStatusChecks(until: date)
        let before = try fixture.files()
        let writes = Counter()
        let observer = NotificationCenter.default.addObserver(forName: PendingStravaUploadStore.didChangeNotification,
                                                              object: nil, queue: nil) { _ in writes.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var credentialReads = 0
        let reader = StravaStatusReader(store: fixture.store, readCredentials: {
            credentialReads += 1
            return .setUp
        })
        for _ in 0..<5 { _ = reader.read() }
        check(credentialReads == 5, "only injected read-only credential lookup is used")
        check(writes.value == 0, "presentation emits no write notifications")
        check(try fixture.files() == before, "all file bytes and inventory unchanged by repeated reads")
        for entry in entries {
            let after = try fixture.store.load(runID: entry.runID)
            check(after == entry, "read does not recover or mutate a durable record")
            check(after?.isPostEligible == entry.isPostEligible, "read cannot change POST eligibility")
        }
        check(try fixture.store.statusNotBefore() == date, "read cannot change reconciliation pacing")
    }

    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private static func record(_ value: Int, phase: PendingStravaUpload.Phase, at date: Date? = nil) -> PendingStravaUpload {
        var result = PendingStravaUpload(runID: id(value), workoutStartDate: date)
        switch phase {
        case .pending: break
        case .retryableFailure: result.preRequestFailed()
        case .submitting: _ = result.beginSubmission()
        case .outcomeUnknown:
            _ = result.beginSubmission()
            result.postOutcomeUnknown()
        case .accepted(let uploadID), .processing(let uploadID):
            _ = result.beginSubmission()
            result.receive(.init(uploadID: uploadID, externalID: nil, statusText: nil,
                                 state: phase == .accepted(uploadID: uploadID) ? .accepted : .processing))
        case .completed(let uploadID, let activityID):
            _ = result.beginSubmission()
            result.receive(.init(uploadID: uploadID, externalID: nil, statusText: nil, state: .completed(activityID: activityID)))
        case .failed(let uploadID), .duplicate(let uploadID):
            _ = result.beginSubmission()
            let duplicate = phase == .duplicate(uploadID: uploadID)
            if let uploadID {
                result.receive(.init(uploadID: uploadID, externalID: nil, statusText: nil,
                                     state: duplicate ? .duplicate(message: "fixture") : .failed(message: "fixture")))
            } else { result.rejected(duplicate: duplicate) }
        }
        return result
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strava-presentation-\(UUID())")
        let store: PendingStravaUploadStore

        init() throws { store = try PendingStravaUploadStore(directory: root) }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func path(_ runID: UUID) -> URL { store.directory.appendingPathComponent(runID.uuidString.lowercased() + ".json") }
        func read(credentials: Presentation.Credentials = .setUp) -> Presentation {
            StravaStatusReader(store: store, readCredentials: { credentials }).read()
        }
        func files() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
    }

    private final class Counter: @unchecked Sendable { var value = 0 }

    private final class DeniedEnumeration: FileManager {
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                          options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
