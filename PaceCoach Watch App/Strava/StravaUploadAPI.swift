import Foundation

enum StravaUploadError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case duplicate
    case network
    case statusDeferred(until: Date)
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

struct StravaStatusCheckResponse {
    let status: StravaUploadStatus
    let retryNotBefore: Date?
}

/// Pure request and response handling shared by the Watch client and checks.
enum StravaUploadAPI {
    static let baseURL = URL(string: "https://www.strava.com/api/v3/")!

    static func externalID(for runID: UUID) -> String {
        "pacecoach-\(runID.uuidString.lowercased())"
    }

    /// A read-only connectivity probe, never an upload or a processing check.
    static func preflightRequest(baseURL: URL = baseURL) -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
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

    /// Strava resets short limits on UTC quarter hours and daily limits at
    /// midnight UTC. Inspect both overall and read budgets, even on HTTP 200.
    static func statusRetryNotBefore(response: HTTPURLResponse, now: Date) -> Date? {
        let quarter = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 900) + 1) * 900 + 1)
        let midnight = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 86400) + 1) * 86400 + 1)
        var deadlines: [Date] = []
        var hasBudgets = false
        for prefix in ["X-RateLimit", "X-ReadRateLimit"] {
            func pair(_ suffix: String) -> [Int]? {
                guard let value = response.value(forHTTPHeaderField: prefix + suffix) else { return nil }
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let short = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let daily = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      short >= 0, daily >= 0 else { return nil }
                return [short, daily]
            }
            if let limit = pair("-Limit"), let usage = pair("-Usage"), limit.allSatisfy({ $0 > 0 }) {
                hasBudgets = true
                if usage[0] >= limit[0] { deadlines.append(quarter) }
                if usage[1] >= limit[1] { deadlines.append(midnight) }
            }
        }
        if let retry = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(retry), seconds.isFinite, seconds >= 0 {
                deadlines.append(now.addingTimeInterval(seconds))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: retry) { deadlines.append(date) }
            }
        }
        deadlines = deadlines.filter { $0 > now }
        if response.statusCode == 429 {
            // Without valid quota headers a daily limit cannot be ruled out.
            if deadlines.isEmpty { deadlines.append(hasBudgets ? quarter : midnight) }
            deadlines.append(now.addingTimeInterval(30))
        }
        return deadlines.max()
    }

    static func decodeStatusResponse(_ data: Data, response: HTTPURLResponse,
                                     uploadID: String, now: Date) throws -> StravaStatusCheckResponse {
        let deadline = statusRetryNotBefore(response: response, now: now)
        do {
            let status = try decode(data, httpStatus: response.statusCode,
                                    submitted: false, expectedUploadID: uploadID)
            return StravaStatusCheckResponse(status: status, retryNotBefore: deadline)
        } catch {
            // Quota/Retry-After evidence is authoritative even when the status
            // body is malformed or the response is a server failure.
            if let deadline { throw StravaUploadError.statusDeferred(until: deadline) }
            throw error
        }
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
