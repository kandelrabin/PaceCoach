import Foundation

struct TCXExportFileWriter {
    enum WriteError: Error {
        case documentsUnavailable
        case existingFileHasDifferentContents
    }

    let fileManager: FileManager
    let documentsDirectory: URL

    init(fileManager: FileManager = .default, documentsDirectory: URL? = nil) throws {
        guard let directory = documentsDirectory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw WriteError.documentsUnavailable
        }
        self.fileManager = fileManager
        self.documentsDirectory = directory
    }

    static func fileName(for runID: UUID) -> String {
        "pacecoach-\(runID.uuidString.lowercased()).tcx"
    }

    func write(_ data: Data, runID: UUID) throws -> URL {
        let directory = documentsDirectory.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(Self.fileName(for: runID), isDirectory: false)

        if fileManager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw WriteError.existingFileHasDifferentContents
            }
            return destination
        }

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tcx", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        // Moving within one sandbox directory avoids replacing an unrelated
        // existing file and makes the finished document visible in one step.
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }
}
