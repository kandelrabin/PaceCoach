import Foundation

/// Latest route result for physical testing; contains no coordinates or tokens.
struct WorkoutRouteDiagnostic: Codable, Equatable {
    let runID: UUID
    let workoutID: UUID?
    let summary: String
}

struct WorkoutRouteDiagnosticStore {
    let fileURL: URL

    init(directory: URL? = nil) throws {
        guard let root = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw CocoaError(.fileNoSuchFile) }
        fileURL = root.appendingPathComponent("WorkoutRouteDiagnostics", isDirectory: true)
            .appendingPathComponent("latest.json")
    }

    func save(_ diagnostic: WorkoutRouteDiagnostic) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(diagnostic).write(to: fileURL, options: .atomic)
    }

    func load(runID: UUID) -> WorkoutRouteDiagnostic? {
        guard let data = try? Data(contentsOf: fileURL),
              let diagnostic = try? JSONDecoder().decode(WorkoutRouteDiagnostic.self, from: data),
              diagnostic.runID == runID else { return nil }
        return diagnostic
    }
}
