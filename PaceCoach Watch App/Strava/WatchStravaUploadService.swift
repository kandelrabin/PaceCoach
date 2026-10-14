import Foundation

/// A single submit or status request. Callers decide when to check again.
@MainActor
final class WatchStravaUploadService {
    static let shared = WatchStravaUploadService()

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// Complete all local work, including token refresh, before the ledger
    /// records an in-flight POST. This method does not submit an upload.
    func prepareUpload(tcxFile: URL, runID: UUID) async throws -> URLRequest {
        let tcx = try Data(contentsOf: tcxFile)
        let token = try await WatchStravaTokenService.shared.validAccessToken().value
        return StravaUploadAPI.uploadRequest(tcx: tcx, runID: runID, accessToken: token)
    }

    func submitPrepared(_ request: URLRequest) async throws -> StravaUploadStatus {
        let (data, response) = try await send(request)
        return try StravaUploadAPI.decode(data, httpStatus: response.statusCode, submitted: true)
    }

    func checkUploadPreflight() async throws {
        // Any HTTP response establishes only that the probe returned. A later
        // POST can still fail ambiguously; never use this to reclassify it.
        _ = try await send(StravaUploadAPI.preflightRequest())
    }

    func checkStatus(uploadID: String) async throws -> StravaUploadStatus {
        let token = try await WatchStravaTokenService.shared.validAccessToken().value
        let request = try StravaUploadAPI.statusRequest(uploadID: uploadID, accessToken: token)
        let (data, response) = try await send(request)
        return try StravaUploadAPI.decode(data, httpStatus: response.statusCode,
                                          submitted: false, expectedUploadID: uploadID)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Do not propagate a URLSession error that might include request details.
            throw StravaUploadError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw StravaUploadError.invalidResponse
        }
        return (data, http)
    }
}
