import Foundation

// swiftc -module-cache-path /tmp/pacecoach-module-cache \
//   'PaceCoach Watch App/Strava/StravaUploadAPI.swift' Tests/StravaUploadChecks.swift \
//   -o /tmp/pacecoach-strava-upload-checks && /tmp/pacecoach-strava-upload-checks
@main
struct StravaUploadChecks {
    private static var checks = 0
    private static let runID = UUID(uuidString: "12345678-ABCD-4321-ABCD-123456789ABC")!

    static func main() throws {
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
        expect(.invalidResponse) { try StravaUploadAPI.statusRequest(uploadID: "../123", accessToken: "secret-test-token") }

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
}
