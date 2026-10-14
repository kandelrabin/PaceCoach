import Foundation
import HealthKit

// Compile with WorkoutRunIdentity.swift, StravaUploadAPI.swift, and
// ManualStravaUploadState.swift. No network or Health database is used.
@main
struct ManualStravaUploadChecks {
    private static var checks = 0
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let runID = UUID(uuidString: "12345678-ABCD-4321-ABCD-123456789ABC")!

    static func main() {
        selection()
        attemptState()
        print("Manual Strava upload checks passed (\(checks) assertions)")
    }

    private static func selection() {
        let currentSource = "com.rabinkandel.PaceCoach"
        let legacySource = "com.rabinkandel.PaceCoach.watchkitapp"
        let configuredSources = PaceCoachSavedRunSelection.acceptedSourceBundleIDs
        check(configuredSources == [currentSource, legacySource], "only the two PaceCoach sources are accepted")
        check(configuredSources.contains(currentSource), "current companion-attributed source accepted")
        check(configuredSources.contains(legacySource), "historical Watch source accepted")
        check(!configuredSources.contains("com.apple.Workout"), "Apple Workout source rejected")
        check(!configuredSources.contains("com.example.running"), "unrelated source rejected")

        let old = workout(at: 0, metadata: [WorkoutRunIdentity.metadataKey: runID.uuidString])
        let latest = workout(at: 200, metadata: [WorkoutRunIdentity.metadataKey: runID.uuidString])
        let appleWorkout = workout(at: 300, metadata: nil)
        let invalidID = workout(at: 350, metadata: [WorkoutRunIdentity.metadataKey: "invalid-uuid"])
        let indoor = workout(at: 400, metadata: [
            WorkoutRunIdentity.metadataKey: runID.uuidString,
            HKMetadataKeyIndoorWorkout: true
        ])
        let otherSport = workout(at: 500, activity: .cycling,
                                 metadata: [WorkoutRunIdentity.metadataKey: runID.uuidString])
        let bundleID = old.sourceRevision.source.bundleIdentifier
        check(PaceCoachSavedRunSelection.latest(
            in: [old, appleWorkout, invalidID, indoor, otherSport, latest],
            acceptedSourceBundleIDs: [bundleID]
        )?.uuid == latest.uuid, "latest eligible outdoor PaceCoach run")
        check(PaceCoachSavedRunSelection.latest(in: [old], acceptedSourceBundleIDs: ["another.app"]) == nil,
              "other app source excluded")
        check(PaceCoachSavedRunSelection.latest(in: [appleWorkout], acceptedSourceBundleIDs: [bundleID]) == nil,
              "run without PaceCoach metadata excluded")
        check(PaceCoachSavedRunSelection.latest(in: [invalidID], acceptedSourceBundleIDs: [bundleID]) == nil,
              "invalid PaceCoach run UUID excluded")
        check(PaceCoachSavedRunSelection.latest(in: [indoor], acceptedSourceBundleIDs: [bundleID]) == nil,
              "indoor run excluded")
        check(PaceCoachSavedRunSelection.latest(in: [otherSport], acceptedSourceBundleIDs: [bundleID]) == nil,
              "other sport excluded")
    }

    private static func attemptState() {
        var attempt = ManualStravaUploadAttempt()
        let file = URL(fileURLWithPath: "/tmp/pacecoach-test.tcx")
        check(attempt.canPrepare && !attempt.canSubmit, "preparation required")
        attempt.preparationFailed()
        check(attempt.canPrepare, "preparation can be retried")
        attempt.prepared(file: file)
        check(attempt.canSubmit, "prepared file can submit")
        check(attempt.beginSubmission(), "first submit starts")
        check(!attempt.beginSubmission() && !attempt.canSubmit, "concurrent submit blocked")
        attempt.receive(status(.accepted))
        check(attempt.uploadID == "123" && attempt.canCheckStatus, "accepted ID retained")
        check(!attempt.beginSubmission(), "accepted upload cannot be reposted")
        attempt.receive(status(.processing))
        check(attempt.phase == .processing, "manual check can report processing")
        attempt.receive(StravaUploadStatus(uploadID: "999", externalID: nil,
                                          statusText: nil, state: .completed(activityID: 888)))
        check(attempt.phase == .processing && attempt.uploadID == "123", "different upload ID ignored")
        attempt.receive(status(.completed(activityID: 456)))
        check(attempt.phase == .completed(456), "completed activity retained")

        var unknown = ManualStravaUploadAttempt()
        unknown.prepared(file: file)
        check(unknown.beginSubmission(), "ambiguous attempt starts")
        unknown.submissionFailed(ambiguous: true)
        check(unknown.phase == .outcomeUnknown && !unknown.canSubmit,
              "ambiguous network outcome blocks repost")

        var duplicate = ManualStravaUploadAttempt()
        duplicate.prepared(file: file)
        check(duplicate.beginSubmission(), "duplicate attempt starts")
        duplicate.submissionFailed(ambiguous: false, duplicate: true)
        check(duplicate.phase == .duplicate && !duplicate.canSubmit, "duplicate blocks repost")
    }

    private static func status(_ state: StravaUploadStatus.State) -> StravaUploadStatus {
        StravaUploadStatus(uploadID: "123", externalID: nil, statusText: nil, state: state)
    }

    private static func workout(
        at offset: TimeInterval,
        activity: HKWorkoutActivityType = .running,
        metadata: [String: Any]?
    ) -> HKWorkout {
        HKWorkout(activityType: activity, start: start.addingTimeInterval(offset),
                  end: start.addingTimeInterval(offset + 60), workoutEvents: nil,
                  totalEnergyBurned: nil, totalDistance: nil, metadata: metadata)
    }

    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
}
