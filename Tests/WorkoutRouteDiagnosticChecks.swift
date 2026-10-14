import Foundation

// Compile with WorkoutRouteDiagnostic.swift. No Health or location access.
@main
struct WorkoutRouteDiagnosticChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkoutRouteDiagnosticStore(directory: root)
        let runID = UUID()
        let workoutID = UUID()
        precondition(store.load(runID: runID) == nil)
        let timedOut = WorkoutRouteDiagnostic(
            runID: runID, workoutID: workoutID,
            summary: "not saved (route insert timed out); accepted=200, inserted=190; timedOut=true"
        )
        try store.save(timedOut)
        let reopened = try WorkoutRouteDiagnosticStore(directory: root)
        precondition(reopened.load(runID: runID) == timedOut)
        precondition(reopened.load(runID: UUID()) == nil)
        let nextRunID = UUID()
        let next = WorkoutRouteDiagnostic(
            runID: nextRunID, workoutID: nil,
            summary: "not saved (saved workout unavailable); locationError=kCLErrorDomain code 0"
        )
        try store.save(next)
        precondition(store.load(runID: nextRunID) == next)
        precondition(store.load(runID: runID) == nil)
        try Data("invalid JSON".utf8).write(to: store.fileURL, options: .atomic)
        precondition(store.load(runID: nextRunID) == nil)
        print("Workout route diagnostic checks passed (6 assertions)")
    }
}
