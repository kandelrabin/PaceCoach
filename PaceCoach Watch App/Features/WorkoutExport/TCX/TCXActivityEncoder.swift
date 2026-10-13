import Foundation

/// Foundation-only TCX v2 activity export. HealthKit and location types stay at
/// the CompletedRunExport boundary.
struct TCXActivityEncoder {
    enum EncodingError: Error {
        case invalidWorkoutTime
        case invalidRoutePoint
    }

    struct Result {
        let data: Data
        let trackCount: Int
        let trackpointCount: Int
        let positionedTrackpointCount: Int
        let heartRateTrackpointCount: Int
        let distanceTrackpointCount: Int
    }

    private static let namespace = "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
    private static let schema = "http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd"
    private static let gapThresholdSeconds: TimeInterval = 15

    func encode(_ run: CompletedRunExport) throws -> Result {
        guard run.start.timeIntervalSince1970.isFinite,
              run.end.timeIntervalSince1970.isFinite,
              run.end >= run.start else { throw EncodingError.invalidWorkoutTime }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let records = try makeRecords(for: run)
        let tracks = segment(records)
        let distance = run.totalDistanceMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }

        // TCX has one required lap duration. Use the wall-clock elapsed time;
        // the separate active duration has no faithful field without pauses.
        // TCX v2 also requires lap distance and calories. Zero denotes
        // unavailable data here, never a measured trackpoint value.
        var lapChildren: [TCXXMLNode] = [
            .text("TotalTimeSeconds", decimal(run.elapsedDurationSeconds)),
            .text("DistanceMeters", decimal(distance ?? 0)),
            .text("Calories", "0"),
            .text("Intensity", "Active"),
            .text("TriggerMethod", "Manual")
        ]
        for track in tracks {
            lapChildren.append(.element("Track", children: track.map { trackpoint($0, formatter: formatter) }))
        }
        let lap = TCXXMLNode.element("Lap", attributes: [("StartTime", formatter.string(from: run.start))], children: lapChildren)
        let activity = TCXXMLNode.element("Activity", attributes: [("Sport", "Running")], children: [
            .text("Id", formatter.string(from: run.start)), lap
        ])
        let root = TCXXMLNode.element("TrainingCenterDatabase", attributes: [
            ("xmlns", Self.namespace),
            ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"),
            ("xsi:schemaLocation", "\(Self.namespace) \(Self.schema)")
        ], children: [.element("Activities", children: [activity])])
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()
        return Result(
            data: Data(xml.utf8), trackCount: tracks.count,
            trackpointCount: records.count,
            positionedTrackpointCount: records.filter { $0.route != nil }.count,
            heartRateTrackpointCount: records.filter { $0.heartRate != nil }.count,
            distanceTrackpointCount: records.filter { $0.distanceMeters != nil }.count
        )
    }

    private struct Record {
        let millisecond: Int64
        var route: CompletedRunExport.RoutePoint?
        var heartRate: Int?
        var distanceMeters: Double?

        var date: Date { Date(timeIntervalSince1970: Double(millisecond) / 1_000) }
    }

    private func makeRecords(for run: CompletedRunExport) throws -> [Record] {
        var byMillisecond: [Int64: Record] = [:]

        func update(_ date: Date, _ apply: (inout Record) -> Void) {
            let key = Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
            var record = byMillisecond[key] ?? Record(millisecond: key)
            apply(&record)
            byMillisecond[key] = record
        }

        for route in CompletedRunExportOrdering.routePoints(run.routePoints) {
            guard route.latitude.isFinite, (-90...90).contains(route.latitude),
                  route.longitude.isFinite, route.longitude >= -180, route.longitude < 180,
                  route.timestamp.timeIntervalSince1970.isFinite else {
                throw EncodingError.invalidRoutePoint
            }
            guard route.timestamp >= run.start, route.timestamp <= run.end else { continue }
            // Same millisecond: retain the earliest ordered real GPS point.
            update(route.timestamp) { if $0.route == nil { $0.route = route } }
        }

        let heartRate = CompletedRunExportOrdering.measurements(run.heartRateBPM).sorted {
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.sourceSampleID.uuidString < $1.sourceSampleID.uuidString
        }
        for reading in heartRate {
            guard reading.end >= run.start, reading.end <= run.end,
                  reading.value.isFinite, reading.value >= 1, reading.value <= 255 else { continue }
            // TCX bpm is an integer. Never average distinct observations.
            update(reading.end) { if $0.heartRate == nil { $0.heartRate = Int(reading.value.rounded()) } }
        }

        // TCX's standard trackpoint fields have no running-speed measurement.
        // Leave that source stream untouched; Strava can derive pace from time
        // and route/distance without a Garmin-specific XML extension.

        if let points = TCXDistanceSeries.cumulativePoints(
            from: run.distanceDeltasMeters, workoutStart: run.start, workoutEnd: run.end
        ) {
            for point in points {
                update(point.timestamp) { $0.distanceMeters = point.cumulativeMeters }
            }
        }
        return byMillisecond.values.sorted { $0.millisecond < $1.millisecond }
    }

    private func segment(_ records: [Record]) -> [[Record]] {
        guard !records.isEmpty else { return [] }
        var tracks: [[Record]] = []
        var current: [Record] = []
        var pendingSensorOnly: [Record] = []
        var previousGPS: Date?

        for record in records {
            if record.route != nil {
                // A >15 s GPS discontinuity starts a new geographical track.
                // Sensor-only points in that gap get their own track.
                if let previousGPS,
                   record.date.timeIntervalSince(previousGPS) > Self.gapThresholdSeconds {
                    if !current.isEmpty { tracks.append(current) }
                    if !pendingSensorOnly.isEmpty { tracks.append(pendingSensorOnly) }
                    current = []
                    pendingSensorOnly = []
                } else {
                    current.append(contentsOf: pendingSensorOnly)
                    pendingSensorOnly = []
                }
                current.append(record)
                previousGPS = record.date
            } else {
                pendingSensorOnly.append(record)
            }
        }
        current.append(contentsOf: pendingSensorOnly)
        if !current.isEmpty { tracks.append(current) }
        return tracks
    }

    private func trackpoint(_ record: Record, formatter: ISO8601DateFormatter) -> TCXXMLNode {
        var children: [TCXXMLNode] = [.text("Time", formatter.string(from: record.date))]
        if let route = record.route {
            children.append(.element("Position", children: [
                .text("LatitudeDegrees", decimal(route.latitude)),
                .text("LongitudeDegrees", decimal(route.longitude))
            ]))
            if let altitude = route.altitudeMeters, altitude.isFinite {
                children.append(.text("AltitudeMeters", decimal(altitude)))
            }
        }
        if let distance = record.distanceMeters {
            children.append(.text("DistanceMeters", decimal(distance)))
        }
        if let heartRate = record.heartRate {
            children.append(.element("HeartRateBpm", children: [.text("Value", String(heartRate))]))
        }
        return .element("Trackpoint", children: children)
    }

    private func decimal(_ value: Double) -> String { String(value) }
}

/// Small typed XML tree: watchOS Foundation provides XMLParser but not
/// XMLDocument/TCXXMLNode serialization. Escaping is centralized here.
enum TCXXMLNode {
    case element(String, attributes: [(String, String)] = [], children: [TCXXMLNode] = [])
    case text(String, String)

    func serialized() -> String {
        switch self {
        case .text(let name, let value):
            return "<\(name)>\(Self.escape(value))</\(name)>"
        case .element(let name, let attributes, let children):
            let attributesString = attributes.map { " \($0.0)=\"\(Self.escape($0.1))\"" }.joined()
            let contents = children.map { $0.serialized() }.joined()
            return "<\(name)\(attributesString)>\(contents)</\(name)>"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
