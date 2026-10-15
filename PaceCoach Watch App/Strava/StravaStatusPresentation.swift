import Foundation

/// Non-secret presentation values. No token, HealthKit, or transport dependency.
struct StravaStatusPresentation: Equatable {
    enum Credentials: Equatable {
        case notSetUp, setUp, unavailable
    }

    enum Status: Equatable {
        case setupRequired, noUploads, waiting, uploading, processing
        case uploaded, duplicate, failed, unconfirmed, unavailable

        var title: String {
            switch self {
            case .setupRequired: "Set up Strava on iPhone"
            case .noUploads: "No uploads yet"
            case .waiting: "Waiting to upload"
            case .uploading: "Uploading to Strava…"
            case .processing: "Sent to Strava · Processing"
            case .uploaded: "Uploaded to Strava"
            case .duplicate: "Strava reported a duplicate"
            case .failed: "Upload failed"
            case .unconfirmed: "Upload unconfirmed"
            case .unavailable: "Upload status unavailable"
            }
        }

        var symbol: String {
            switch self {
            case .setupRequired: "iphone"
            case .noUploads: "arrow.up.circle"
            case .waiting: "clock"
            case .uploading: "arrow.up.circle"
            case .processing: "hourglass"
            case .uploaded: "checkmark.circle"
            case .duplicate, .failed, .unconfirmed, .unavailable: "exclamationmark.circle"
            }
        }

        var needsAttention: Bool {
            self == .duplicate || self == .failed || self == .unconfirmed
        }

        var isInProgress: Bool {
            self == .waiting || self == .uploading || self == .processing
        }

        var explanation: String? {
            switch self {
            case .waiting:
                "Retries while PaceCoach is open. If needed, reconnect on iPhone."
            case .processing:
                "Checks automatically while PaceCoach is open."
            case .duplicate:
                "Check your activities in Strava."
            case .failed:
                "Check Strava. If needed, reconnect on iPhone."
            case .unconfirmed:
                "May already be on Strava. PaceCoach won’t resend it automatically."
            default: nil
            }
        }

        init(phase: PendingStravaUpload.Phase) {
            switch phase {
            case .pending, .retryableFailure: self = .waiting
            case .submitting: self = .uploading
            case .accepted, .processing: self = .processing
            case .completed: self = .uploaded
            case .duplicate: self = .duplicate
            case .failed: self = .failed
            case .outcomeUnknown: self = .unconfirmed
            }
        }
    }

    struct Run: Identifiable, Equatable {
        let id: UUID
        let date: Date?
        let status: Status
    }

    let credentials: Credentials
    let isUploadStatusUnavailable: Bool
    let runs: [Run]

    init(credentials: Credentials, snapshot: PendingStravaUploadStore.PresentationSnapshot) {
        self.credentials = credentials
        isUploadStatusUnavailable = snapshot.isUnavailable
        runs = snapshot.records.map {
            Run(id: $0.runID, date: $0.workoutStartDate, status: Status(phase: $0.phase))
        }.sorted {
            switch ($0.date, $1.date) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    var attentionRuns: [Run] {
        runs.filter { $0.status.needsAttention || $0.status.isInProgress }
    }

    /// Only a real workout date can establish the most recent success. Undated
    /// successes stay in the snapshot but do not form a history on the Watch.
    var recentUpload: Run? {
        runs.first { $0.status == .uploaded && $0.date != nil }
    }

    var summary: Status {
        if isUploadStatusUnavailable || credentials == .unavailable { return .unavailable }
        if credentials == .notSetUp { return .setupRequired }
        // A newer success must never hide older runs that still need attention.
        for status: Status in [.unconfirmed, .failed, .duplicate, .uploading, .waiting, .processing] {
            if runs.contains(where: { $0.status == status }) { return status }
        }
        return runs.isEmpty ? .noUploads : .uploaded
    }

    var homeSubtitle: String { summary == .noUploads ? "Uploads automatically" : summary.title }
}

/// Reading this projection cannot start the coordinator, recover a submission,
/// create a record, or request any workout/export/network work.
struct StravaStatusReader {
    let store: PendingStravaUploadStore?
    let readCredentials: () -> StravaStatusPresentation.Credentials

    func read() -> StravaStatusPresentation {
        StravaStatusPresentation(credentials: readCredentials(),
                                 snapshot: store?.presentationSnapshot() ?? .unavailable)
    }
}
