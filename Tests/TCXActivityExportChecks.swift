import Foundation

// Compile with CompletedRunExport.swift and the three TCX production sources.
@main
struct TCXActivityExportChecks {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let runID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    private static var checks = 0

    static func main() throws {
        try fullRun()
        try sparseAndMissingData()
        try gapsAndOrdering()
        try timestampCollisions()
        distanceSeries()
        try overlappingDistanceOmitted()
        try fileWriting()
        xmlEscaping()
        print("TCX activity export checks passed (\(checks) assertions)")
    }

    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    private static func sample(_ from: Double, _ to: Double, _ value: Double, id: String) -> CompletedRunExport.Measurement {
        CompletedRunExport.Measurement(
            sourceSampleID: UUID(uuidString: id)!,
            start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), value: value
        )
    }

    private static func route(_ at: Double, altitude: Double? = nil) -> CompletedRunExport.RoutePoint {
        CompletedRunExport.RoutePoint(
            timestamp: start.addingTimeInterval(at), latitude: 51.5 + at / 10_000,
            longitude: -0.12, altitudeMeters: altitude,
            horizontalAccuracyMeters: 5, verticalAccuracyMeters: altitude == nil ? nil : 5,
            gpsSpeedMetersPerSecond: nil, courseDegrees: nil
        )
    }

    private static func run(
        routes: [CompletedRunExport.RoutePoint] = [],
        heartRates: [CompletedRunExport.Measurement] = [],
        distances: [CompletedRunExport.Measurement] = [],
        total: Double? = 120
    ) -> CompletedRunExport {
        CompletedRunExport(
            runID: runID, healthKitWorkoutID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            activity: .outdoorRun, start: start, end: start.addingTimeInterval(60),
            activeDurationSeconds: 55, timeZoneIdentifier: "Europe/London",
            totalDistanceMeters: total, heartRateBPM: heartRates,
            distanceDeltasMeters: distances, runningSpeedMetersPerSecond: [
                sample(1, 2, 2.5, id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
            ], routePoints: routes
        )
    }

    private static func document(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [])
    }

    private static func nodes(_ xpath: String, in document: XMLDocument) throws -> [XMLNode] {
        try document.nodes(forXPath: xpath)
    }

    private static func fullRun() throws {
        let hr = sample(1, 2, 143, id: "11111111-1111-1111-1111-111111111111")
        let d1 = sample(0, 10, 20, id: "22222222-2222-2222-2222-222222222222")
        let d2 = sample(10, 20, 30, id: "33333333-3333-3333-3333-333333333333")
        let encoded = try TCXActivityEncoder().encode(run(
            routes: [route(0, altitude: 42), route(2), route(20, altitude: 47)],
            heartRates: [hr], distances: [d1, d2]
        ))
        if let output = ProcessInfo.processInfo.environment["TCX_TEST_OUTPUT_PATH"] {
            try encoded.data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        let xml = try document(encoded.data)
        check(xml.rootElement()?.name == "TrainingCenterDatabase", "TCX root")
        check(xml.rootElement()?.uri == "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2", "TCX namespace")
        check(try nodes("//*[local-name()='Activity']/@Sport", in: xml).first?.stringValue == "Running", "Running sport")
        check(try nodes("//*[local-name()='Activity']/*[local-name()='Id']", in: xml).first?.stringValue == "2023-11-14T22:13:20.000Z", "UTC activity time")
        check(try nodes("//*[local-name()='Lap']/@StartTime", in: xml).first?.stringValue == "2023-11-14T22:13:20.000Z", "UTC lap start")
        check(try nodes("//*[local-name()='Lap']/*[local-name()='TotalTimeSeconds']", in: xml).first?.stringValue == "60.0", "Elapsed lap duration")
        check(try nodes("//*[local-name()='Lap']/*[local-name()='DistanceMeters']", in: xml).first?.stringValue == "120.0", "Saved workout total")
        check(try nodes("//*[local-name()='Lap']/*[local-name()='Calories']", in: xml).first?.stringValue == "0", "Required unknown calorie placeholder")
        check(try nodes("//*[local-name()='Trackpoint']/*[local-name()='Position']/*[local-name()='LatitudeDegrees']", in: xml).count == 3, "Real GPS positions")
        check(try nodes("//*[local-name()='AltitudeMeters']", in: xml).map { $0.stringValue ?? "" } == ["42.0", "47.0"], "Only actual altitude")
        check(try nodes("//*[local-name()='HeartRateBpm']/*[local-name()='Value']", in: xml).first?.stringValue == "143", "Actual HR observation")
        check(try nodes("//*[local-name()='Trackpoint']/*[local-name()='DistanceMeters']", in: xml).map { $0.stringValue ?? "" } == ["20.0", "50.0"], "Cumulative interval distance")
        check(encoded.trackpointCount == 4 && encoded.heartRateTrackpointCount == 1, "Sparse union timeline")
        check(!String(decoding: encoded.data, as: UTF8.self).contains("<Speed>"), "Unconsumed speed remains unexported")
    }

    private static func sparseAndMissingData() throws {
        let hr = sample(5, 6, 130, id: "44444444-4444-4444-4444-444444444444")
        let encoded = try TCXActivityEncoder().encode(run(routes: [route(0), route(10)], heartRates: [hr], total: nil))
        let xml = try document(encoded.data)
        check(try nodes("//*[local-name()='Trackpoint']", in: xml).count == 3, "Sensor-only timestamp yields trackpoint")
        check(try nodes("//*[local-name()='Trackpoint']/*[local-name()='Position']", in: xml).count == 2, "HR point does not borrow GPS")
        check(try nodes("//*[local-name()='Trackpoint']/*[local-name()='HeartRateBpm']", in: xml).count == 1, "GPS points do not borrow HR")
        check(try nodes("//*[local-name()='Lap']/*[local-name()='DistanceMeters']", in: xml).first?.stringValue == "0.0", "Missing required lap summary is explicit zero")
        let noGPS = try TCXActivityEncoder().encode(run(heartRates: [hr]))
        check(noGPS.trackpointCount == 1 && noGPS.positionedTrackpointCount == 0, "Missing GPS stays missing")
    }

    private static func gapsAndOrdering() throws {
        let hr = sample(30, 31, 150, id: "55555555-5555-5555-5555-555555555555")
        let a = run(routes: [route(45), route(0), route(1)], heartRates: [hr])
        let b = run(routes: a.routePoints.reversed(), heartRates: a.heartRateBPM.reversed())
        let first = try TCXActivityEncoder().encode(a)
        let second = try TCXActivityEncoder().encode(b)
        check(first.data == second.data, "Source query order does not change XML")
        check(first.trackCount == 3, "Long GPS gap has two route tracks and one sensor-only track")
        let xml = try document(first.data)
        let positions = try nodes("//*[local-name()='Position']", in: xml)
        check(positions.count == 3, "No interpolated GPS point")
    }

    private static func distanceSeries() {
        let first = sample(0, 10, 20, id: "66666666-6666-6666-6666-666666666666")
        let duplicate = sample(0, 10, 20, id: "77777777-7777-7777-7777-777777777777")
        let afterGap = sample(20, 30, 5, id: "88888888-8888-8888-8888-888888888888")
        let points = TCXDistanceSeries.cumulativePoints(
            from: [afterGap, duplicate, first], workoutStart: start, workoutEnd: start.addingTimeInterval(60)
        )
        check(points?.map(\.cumulativeMeters) == [20, 25], "Duplicate counted once and gap not filled")
        check(points?.map(\.timestamp) == [start.addingTimeInterval(10), start.addingTimeInterval(30)], "Distance only at interval ends")
    }

    private static func timestampCollisions() throws {
        let first = sample(0, 2.0001, 130, id: "00000000-0000-0000-0000-000000000001")
        let second = sample(0, 2.0009, 155, id: "00000000-0000-0000-0000-000000000002")
        let forward = try TCXActivityEncoder().encode(run(heartRates: [first, second]))
        let reverse = try TCXActivityEncoder().encode(run(heartRates: [second, first]))
        check(forward.data == reverse.data, "Same-millisecond readings have stable order")
        let xml = try document(forward.data)
        check(try nodes("//*[local-name()='HeartRateBpm']/*[local-name()='Value']", in: xml).map(\.stringValue) == ["130"],
              "Earliest real reading wins a timestamp collision without averaging")
    }

    private static func overlappingDistanceOmitted() throws {
        let a = sample(0, 10, 20, id: "99999999-9999-9999-9999-999999999999")
        let b = sample(5, 15, 20, id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        check(TCXDistanceSeries.cumulativePoints(from: [a, b], workoutStart: start,
                                                 workoutEnd: start.addingTimeInterval(60)) == nil,
              "Overlap invalidates the whole series")
        let encoded = try TCXActivityEncoder().encode(run(routes: [route(1)], distances: [a, b]))
        let xml = try document(encoded.data)
        check(try nodes("//*[local-name()='Trackpoint']/*[local-name()='DistanceMeters']", in: xml).isEmpty,
              "Ambiguous record distance omitted")
        check(try nodes("//*[local-name()='Lap']/*[local-name()='DistanceMeters']", in: xml).first?.stringValue == "120.0",
              "Saved summary remains authoritative")
    }

    private static func fileWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try TCXExportFileWriter(documentsDirectory: root)
        let data = try TCXActivityEncoder().encode(run(routes: [route(0)])).data
        let url = try writer.write(data, runID: runID)
        check(url.lastPathComponent == "pacecoach-12345678-1234-1234-1234-123456789abc.tcx", "Stable filename")
        check(try Data(contentsOf: url) == data, "File contents")
        check(try writer.write(data, runID: runID) == url, "Identical repeat is idempotent")
        do {
            _ = try writer.write(Data("different".utf8), runID: runID)
            preconditionFailure("Unrelated file overwritten")
        } catch TCXExportFileWriter.WriteError.existingFileHasDifferentContents {
            checks += 1
        }
    }

    private static func xmlEscaping() {
        let value = TCXXMLNode.element("Test", attributes: [("name", "A&B\"'<")],
                                    children: [.text("Value", "A&B\"'<")]).serialized()
        check(value == "<Test name=\"A&amp;B&quot;&apos;&lt;\"><Value>A&amp;B&quot;&apos;&lt;</Value></Test>",
              "Attribute and text escaping")
    }
}
