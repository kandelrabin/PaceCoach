import Foundation

enum StravaUploadError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case duplicate
    case network
}

struct StravaUploadStatus: Equatable {
    enum State: Equatable {
        case accepted
        case processing
        case completed(activityID: Int64)
        case failed(message: String)
        case duplicate(message: String)
    }

    let uploadID: String
    let externalID: String?
    let statusText: String?
    let state: State
}

/// Pure request and response handling shared by the Watch client and checks.
enum StravaUploadAPI {
    static let baseURL = URL(string: "https://www.strava.com/api/v3/")!

    static func externalID(for runID: UUID) -> String {
        "pacecoach-\(runID.uuidString.lowercased())"
    }

    static func uploadRequest(
        tcx: Data, runID: UUID, accessToken: String,
        boundary: String = "PaceCoach-\(UUID().uuidString)", baseURL: URL = baseURL
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("uploads"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("data_type", "tcx")
        field("external_id", externalID(for: runID))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(externalID(for: runID)).tcx\"\r\nContent-Type: application/vnd.garmin.tcx+xml\r\n\r\n".utf8))
        body.append(tcx)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func statusRequest(uploadID: String, accessToken: String, baseURL: URL = baseURL) throws -> URLRequest {
        guard !uploadID.isEmpty, uploadID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw StravaUploadError.invalidResponse
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("uploads/\(uploadID)"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func decode(_ data: Data, httpStatus: Int, submitted: Bool, expectedUploadID: String? = nil) throws -> StravaUploadStatus {
        guard httpStatus == (submitted ? 201 : 200) else {
            if let fault = try? JSONDecoder().decode(Fault.self, from: data),
               fault.message.localizedCaseInsensitiveContains("duplicate") {
                throw StravaUploadError.duplicate
            }
            throw StravaUploadError.httpStatus(httpStatus)
        }
        guard let upload = try? JSONDecoder().decode(Upload.self, from: data),
              let uploadID = upload.idStr ?? upload.id.map(String.init),
              !uploadID.isEmpty, uploadID.allSatisfy({ $0.isASCII && $0.isNumber }),
              expectedUploadID == nil || expectedUploadID == uploadID else {
            throw StravaUploadError.invalidResponse
        }
        let message = upload.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = upload.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state: StravaUploadStatus.State
        if let message, !message.isEmpty {
            state = message.localizedCaseInsensitiveContains("duplicate")
                ? .duplicate(message: message) : .failed(message: message)
        } else if let activityID = upload.activityID {
            guard activityID > 0 else { throw StravaUploadError.invalidResponse }
            state = .completed(activityID: activityID)
        } else if let status, !status.isEmpty {
            if status.localizedCaseInsensitiveContains("ready") {
                throw StravaUploadError.invalidResponse
            }
            if status.localizedCaseInsensitiveContains("duplicate") {
                state = .duplicate(message: status)
            } else if status.localizedCaseInsensitiveContains("error") || status.localizedCaseInsensitiveContains("deleted") {
                state = .failed(message: status)
            } else {
                state = submitted ? .accepted : .processing
            }
        } else {
            throw StravaUploadError.invalidResponse
        }
        return StravaUploadStatus(uploadID: uploadID, externalID: upload.externalID,
                                  statusText: status, state: state)
    }
}

private struct Upload: Decodable {
    let id: Int64?
    let idStr: String?
    let externalID: String?
    let error: String?
    let status: String?
    let activityID: Int64?

    enum CodingKeys: String, CodingKey {
        case id, error, status
        case idStr = "id_str"
        case externalID = "external_id"
        case activityID = "activity_id"
    }
}

private struct Fault: Decodable {
    let message: String
}
