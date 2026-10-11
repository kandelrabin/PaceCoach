import Foundation

/// Sample-driven decisions for one frozen workout target. The owner signals
/// missing/stale HR with heartRateUnavailable(); no wall-clock timers live here.
struct ZoneDecisionEngine {
    enum CoachingState: Equatable {
        case findingZone
        case inZone
        case increaseEffort
        case reduceEffort
    }

    private enum Direction {
        case increase
        case reduce
    }

    private static let inRangeDuration: TimeInterval = 5
    private static let confirmationDuration: TimeInterval = 10
    private static let entryHysteresis: Double = 3

    let target: TargetHeartRateZone
    private(set) var isCoachingActive = false
    private(set) var coachingState: CoachingState = .findingZone
    private var lastSampleDate: Date?
    private var inRangeSince: Date?
    private var pendingDirection: Direction?
    private var pendingSince: Date?
    private var confirmedDirection: Direction?

    init(target: TargetHeartRateZone) {
        self.target = target
    }

    @discardableResult
    mutating func addSample(bpm: Double, at date: Date) -> CoachingState {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            heartRateUnavailable()
            return coachingState
        }
        // Duplicate/out-of-order samples cannot advance or interrupt a timer.
        guard lastSampleDate.map({ date > $0 }) ?? true else { return coachingState }
        lastSampleDate = date
        guard bpm.isFinite, bpm > 0 else {
            heartRateUnavailable()
            return coachingState
        }

        let lower = Double(target.lowerBPM)
        let upper = Double(target.upperBPM)
        let isInside = bpm >= lower && bpm <= upper

        if !isCoachingActive {
            if isInside {
                if inRangeSince == nil { inRangeSince = date }
                if let inRangeSince, date.timeIntervalSince(inRangeSince) >= Self.inRangeDuration {
                    isCoachingActive = true
                    self.inRangeSince = nil
                    coachingState = .inZone
                }
            } else {
                inRangeSince = nil
            }
            return coachingState
        }

        // Strict entry thresholds: equality at lower-3 or upper+3 is neutral.
        // Every neutral/in-range/opposite sample interrupts the pending direction.
        let candidate: Direction?
        if bpm < lower - Self.entryHysteresis {
            candidate = .increase
        } else if bpm > upper + Self.entryHysteresis {
            candidate = .reduce
        } else {
            candidate = nil
        }
        let pending = candidate == confirmedDirection ? nil : candidate
        if pending != pendingDirection {
            pendingDirection = pending
            pendingSince = pending == nil ? nil : date
        }

        if let pendingDirection, let pendingSince,
           date.timeIntervalSince(pendingSince) >= Self.confirmationDuration {
            confirmedDirection = pendingDirection
            self.pendingDirection = nil
            self.pendingSince = nil
            inRangeSince = nil
        }

        if confirmedDirection != nil {
            if isInside {
                if inRangeSince == nil { inRangeSince = date }
                if let inRangeSince, date.timeIntervalSince(inRangeSince) >= Self.inRangeDuration {
                    confirmedDirection = nil
                    self.inRangeSince = nil
                    coachingState = .inZone
                }
            } else {
                inRangeSince = nil
            }
        } else if isInside {
            // After an outage the latch survives, but the old direction does not.
            // Valid in-range HR can resume In Zone without warming up again.
            coachingState = .inZone
        }

        switch confirmedDirection {
        case .increase: coachingState = .increaseEffort
        case .reduce: coachingState = .reduceEffort
        case nil: break // Keep Finding Zone after an outage until evidence returns.
        }
        return coachingState
    }

    mutating func heartRateUnavailable() {
        inRangeSince = nil
        pendingDirection = nil
        pendingSince = nil
        confirmedDirection = nil
        coachingState = .findingZone
        // Keep activation and the timestamp watermark for this workout.
    }

    mutating func resetWorkout() {
        heartRateUnavailable()
        isCoachingActive = false
        lastSampleDate = nil
    }
}
