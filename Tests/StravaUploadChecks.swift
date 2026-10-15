import Foundation

// swiftc -module-cache-path /tmp/pacecoach-module-cache \
//   'PaceCoach Watch App/Strava/StravaUploadAPI.swift' Tests/StravaUploadChecks.swift \
//   -o /tmp/pacecoach-strava-upload-checks && /tmp/pacecoach-strava-upload-checks
@main
struct StravaUploadChecks {
    private static var checks = 0
    private static let runID = UUID(uuidString: "12345678-ABCD-4321-ABCD-123456789ABC")!

    static func main() throws {
        let preflight = StravaUploadAPI.preflightRequest()
        check(preflight.url == StravaUploadAPI.baseURL && preflight.httpMethod == "HEAD", "read-only probe to Strava origin")
        check(preflight.httpBody == nil && preflight.value(forHTTPHeaderField: "Authorization") == nil,
              "preflight contains no TCX or credentials")
        check(preflight.timeoutInterval == 5 && preflight.cachePolicy == .reloadIgnoringLocalCacheData,
              "short probe ignores local cached responses")
        check(preflight.value(forHTTPHeaderField: "Cache-Control") == "no-cache", "probe requests revalidation")
        let externalID = "pacecoach-12345678-abcd-4321-abcd-123456789abc"
        check(StravaUploadAPI.externalID(for: runID) == externalID, "stable lowercase external ID")
        check(StravaUploadAPI.externalID(for: runID) == StravaUploadAPI.externalID(for: runID), "repeat attempt ID")

        let request = StravaUploadAPI.uploadRequest(
            tcx: Data("<tcx>route</tcx>".utf8), runID: runID,
            accessToken: "secret-test-token", boundary: "fixed-boundary"
        )
        check(request.url?.absoluteString == "https://www.strava.com/api/v3/uploads", "upload URL")
        check(request.httpMethod == "POST", "upload method")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-test-token", "bearer header")
        check(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=fixed-boundary", "multipart header")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        check(body.contains("name=\"data_type\"\r\n\r\ntcx\r\n"), "TCX data type")
        check(body.contains("name=\"external_id\"\r\n\r\n\(externalID)\r\n"), "external ID field")
        check(body.contains("name=\"file\"; filename=\"\(externalID).tcx\""), "file field")
        check(body.contains("\r\n\r\n<tcx>route</tcx>\r\n--fixed-boundary--\r\n"), "TCX bytes and final boundary")
        check(!body.contains("secret-test-token"), "token absent from body")
        let checkRequest = try StravaUploadAPI.statusRequest(uploadID: "123", accessToken: "secret-test-token")
        check(checkRequest.url?.absoluteString == "https://www.strava.com/api/v3/uploads/123", "status URL")
        check(checkRequest.httpMethod == "GET", "status method")
        check(checkRequest.httpBody == nil && checkRequest.cachePolicy == .reloadIgnoringLocalCacheData, "status GET has no upload body and bypasses cached status")
        expect(.invalidResponse) { try StravaUploadAPI.statusRequest(uploadID: "../123", accessToken: "secret-test-token") }
        rateLimits()

        let accepted = try decode(#"{"id":123,"id_str":"123","external_id":"pacecoach-test.tcx","error":null,"status":"Your activity is still being processed.","activity_id":null}"#, 201, true)
        check(accepted.uploadID == "123" && accepted.state == .accepted, "201 means accepted")
        let processing = try decode(#"{"id_str":"123","status":"Your activity is still being processed."}"#, 200, false, expected: "123")
        check(processing.state == .processing, "GET pending")
        let completed = try decode(#"{"id_str":"123","status":"Your activity is ready.","activity_id":5000000000}"#, 200, false, expected: "123")
        check(completed.state == .completed(activityID: 5_000_000_000), "64-bit completed activity")
        let failed = try decode(#"{"id":123,"status":"There was an error processing your activity.","error":"Invalid TCX"}"#, 200, false)
        check(failed.state == .failed(message: "Invalid TCX"), "processing failure")
        let duplicate = try decode(#"{"id":123,"status":"There was an error processing your activity.","error":"duplicate of activity 42"}"#, 200, false)
        check(duplicate.state == .duplicate(message: "duplicate of activity 42"), "processing duplicate")
        let statusDuplicate = try decode(#"{"id":123,"status":"Duplicate activity"}"#, 200, false)
        check(statusDuplicate.state == .duplicate(message: "Duplicate activity"), "status-only duplicate")
        let statusFailure = try decode(#"{"id":123,"status":"The created activity has been deleted."}"#, 200, false)
        check(statusFailure.state == .failed(message: "The created activity has been deleted."), "status-only failure")
        expect(.duplicate) { try decode(#"{"message":"duplicate activity"}"#, 400, true) }
        expect(.httpStatus(401)) { try decode(#"{"message":"unauthorized"}"#, 401, true) }
        expect(.invalidResponse) { try decode(#"{"status":"pending"}"#, 201, true) }
        expect(.invalidResponse) { try decode(#"{"id":123,"status":"Your activity is ready."}"#, 200, false) }
        expect(.invalidResponse) { try decode(#"{"id":123,"activity_id":0}"#, 200, false) }
        expect(.invalidResponse) { try decode(#"{"id":123,"status":"pending"}"#, 200, false, expected: "456") }
        expect(.invalidResponse) { try decode("not JSON", 201, true) }

        // Neither error descriptions nor production source contain a logging call.
        check(!String(describing: StravaUploadError.network).contains("secret-test-token"), "network error redacts request")
        print("Strava upload checks passed (\(checks) assertions)")
    }

    private static func decode(_ json: String, _ status: Int, _ submitted: Bool, expected: String? = nil) throws -> StravaUploadStatus {
        try StravaUploadAPI.decode(Data(json.utf8), httpStatus: status, submitted: submitted, expectedUploadID: expected)
    }

    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    private static func expect(_ error: StravaUploadError, _ operation: () throws -> Any) {
        do {
            _ = try operation()
            preconditionFailure("Expected \(error)")
        } catch let received as StravaUploadError {
            check(received == error, "Expected \(error), got \(received)")
        } catch {
            preconditionFailure("Unexpected error \(error)")
        }
    }

    private static func rateLimits() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quarter = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 900) + 1) * 900 + 1)
        let midnight = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 86400) + 1) * 86400 + 1)
        func deadline(_ code: Int = 200, _ headers: [String: String] = [:]) -> Date? {
            let response = HTTPURLResponse(url: URL(string: "https://example.invalid/uploads/1")!, statusCode: code, httpVersion: nil, headerFields: headers)!
            return StravaUploadAPI.statusRetryNotBefore(response: response, now: now)
        }
        check(deadline() == nil, "missing headers on success do not invent a limit")
        check(deadline(200, ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "199,1999"]) == nil, "available overall budget")
        check(deadline(200, ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "200,1999"]) == quarter, "HTTP 200 can exhaust quarter-hour budget")
        check(deadline(200, ["X-ReadRateLimit-Limit": "100,1000", "X-ReadRateLimit-Usage": "1,1000"]) == midnight, "read daily budget defers to UTC midnight")
        check(deadline(429, ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "201,2001"]) == midnight, "daily exhaustion takes precedence over quarter")
        check(deadline(429) == midnight, "headerless 429 conservatively permits daily exhaustion")
        check(deadline(429, ["X-RateLimit-Limit": "bad", "X-RateLimit-Usage": "bad"]) == midnight, "malformed quota headers fail conservatively")
        check(deadline(429, ["X-RateLimit-Limit": "100,bad,1000", "X-RateLimit-Usage": "1,bad,1"]) == midnight, "three-component quota headers rejected")
        check(deadline(429, ["X-RateLimit-Limit": "100,,1000", "X-RateLimit-Usage": "1,,1"]) == midnight, "empty quota component cannot be compacted away")
        check(deadline(429, ["Retry-After": "120"]) == now + 120, "Retry-After seconds honored")
        check(deadline(429, ["Retry-After": "0"]) == midnight, "zero Retry-After cannot bypass unknown quota exhaustion")
        check(deadline(429, ["Retry-After": "-1"]) == midnight, "negative Retry-After rejected")
        check(deadline(429, ["Retry-After": "inf"]) == midnight, "nonfinite Retry-After rejected")
        check(deadline(429, ["Retry-After": "Wed, 15 Nov 2023 00:00:00 GMT"]) == Date(timeIntervalSince1970: 1_700_006_400), "HTTP-date Retry-After parsed in UTC")
        check(deadline(429, ["Retry-After": "Mon, 13 Nov 2023 00:00:00 GMT"]) == midnight, "expired Retry-After cannot bypass quota fallback")
        check(deadline(200, ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "200,100", "X-ReadRateLimit-Limit": "100,1000", "X-ReadRateLimit-Usage": "99,1000"]) == midnight, "both read and overall budgets constrain status recovery")
        let server = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "3600"])!
        expect(.statusDeferred(until: now + 3600)) { try StravaUploadAPI.decodeStatusResponse(Data(), response: server, uploadID: "1", now: now) }
        let exhausted = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: ["X-ReadRateLimit-Limit": "100,1000", "X-ReadRateLimit-Usage": "20,1000"])!
        expect(.statusDeferred(until: midnight)) { try StravaUploadAPI.decodeStatusResponse(Data("malformed".utf8), response: exhausted, uploadID: "1", now: now) }
    }
}
