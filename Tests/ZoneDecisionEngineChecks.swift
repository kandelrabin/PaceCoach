import Foundation

// Run with:
// swiftc 'PaceCoach Watch App/Features/HeartRate/HeartRateZoneCalculator.swift' \
//   'PaceCoach Watch App/Features/HeartRate/ZoneDecisionEngine.swift' \
//   Tests/ZoneDecisionEngineChecks.swift -o /tmp/zone-engine-checks && /tmp/zone-engine-checks
@main
struct ZoneDecisionEngineChecks {
    private static let target = TargetHeartRateZone(number: 2, lowerBPM: 145, upperBPM: 155)
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    private static var checks = 0

    static func main() {
        activation()
        hysteresis()
        confirmation()
        recovery()
        reversal()
        missingAndReset()
        invalidAndUnorderedSamples()
        print("ZoneDecisionEngine checks passed (\(checks) assertions)")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    private static func sample(_ engine: inout ZoneDecisionEngine, _ bpm: Double, _ time: Double,
                               _ expected: ZoneDecisionEngine.CoachingState, _ message: String) {
        check(engine.addSample(bpm: bpm, at: epoch.addingTimeInterval(time)) == expected, message)
    }

    private static func activated() -> ZoneDecisionEngine {
        var engine = ZoneDecisionEngine(target: target)
        sample(&engine, 145, 0, .findingZone, "Activation starts at inclusive lower bound")
        sample(&engine, 155, 5, .inZone, "Activation includes upper bound at exactly 5 seconds")
        return engine
    }

    private static func activation() {
        var engine = ZoneDecisionEngine(target: target)
        check(engine.coachingState == .findingZone && !engine.isCoachingActive, "Initially inactive")
        sample(&engine, 130, 0, .findingZone, "Warmup below zone has no instruction")
        sample(&engine, 170, 20, .findingZone, "Warmup above zone has no instruction")
        sample(&engine, 150, 21, .findingZone, "Begin activation")
        sample(&engine, 150, 25.999, .findingZone, "Not active before five seconds")
        sample(&engine, 144.9, 26, .findingZone, "Actual range excursion resets activation")
        sample(&engine, 150, 27, .findingZone, "Restart activation")
        sample(&engine, 151, 29.7, .findingZone, "Irregular cadence is supported")
        sample(&engine, 155, 32, .inZone, "Five continuous seconds activates")
        check(engine.isCoachingActive, "Activation latch set")
    }

    private static func hysteresis() {
        var engine = activated()
        for (index, bpm) in [144.0, 142, 156, 158, 145, 155].enumerated() {
            let time = 6 + Double(index) * 11
            sample(&engine, bpm, time, .inZone, "Neutral band including exact entry threshold")
            sample(&engine, bpm, time + 10, .inZone, "Neutral band never confirms an instruction")
        }
        sample(&engine, 141.99, 72, .inZone, "Fractional value below strict threshold starts candidate")
        sample(&engine, 141.99, 81.99, .inZone, "Strict candidate not yet confirmed")
        sample(&engine, 141.99, 82, .increaseEffort, "Strict lower threshold confirms at ten seconds")

        var upper = activated()
        sample(&upper, 158.01, 6, .inZone, "Fractional value above strict upper threshold")
        sample(&upper, 158.01, 16, .reduceEffort, "Strict upper threshold confirms")
    }

    private static func confirmation() {
        for (bpm, state) in [(140.0, ZoneDecisionEngine.CoachingState.increaseEffort), (160.0, .reduceEffort)] {
            var engine = activated()
            sample(&engine, bpm, 6, .inZone, "Candidate begins without changing guidance")
            sample(&engine, bpm, 10.4, .inZone, "Multiple updates do not accelerate confirmation")
            sample(&engine, bpm, 15.999, .inZone, "Candidate needs full ten seconds")
            sample(&engine, bpm, 16, state, "Candidate confirms at exactly ten seconds")
            sample(&engine, bpm, 17, state, "Confirmed direction persists")
        }
        var engine = activated()
        sample(&engine, 140, 6, .inZone, "Start below candidate")
        sample(&engine, 142, 15, .inZone, "Threshold equality cancels candidate")
        sample(&engine, 140, 16, .inZone, "Below starts a new interval")
        sample(&engine, 140, 25.999, .inZone, "Earlier candidate time is discarded")
        sample(&engine, 140, 26, .increaseEffort, "Interrupted candidate requires fresh ten seconds")

        var opposite = activated()
        sample(&opposite, 140, 6, .inZone, "Begin below")
        sample(&opposite, 160, 15, .inZone, "Opposite sample restarts pending confirmation")
        sample(&opposite, 160, 24.999, .inZone, "No time carried from below to above")
        sample(&opposite, 160, 25, .reduceEffort, "Opposite candidate confirms independently")
    }

    private static func recovery() {
        for (bpm, band, state) in [(140.0, 144.0, ZoneDecisionEngine.CoachingState.increaseEffort), (160.0, 156.0, .reduceEffort)] {
            var engine = activated()
            sample(&engine, bpm, 6, .inZone, "Begin effort candidate")
            sample(&engine, bpm, 16, state, "Confirm effort candidate")
            sample(&engine, band, 17, state, "Hysteresis band is not recovery")
            sample(&engine, band, 27, state, "Time in hysteresis band cannot recover")
            sample(&engine, 145, 28, state, "Start actual-range recovery")
            sample(&engine, 155, 32.999, state, "Recovery needs full five seconds")
            sample(&engine, band, 33, state, "Even small excursion interrupts recovery")
            sample(&engine, 155, 34, state, "Restart actual-range recovery")
            sample(&engine, 145, 39, .inZone, "Recover at exactly five seconds")
        }
    }

    private static func reversal() {
        var engine = activated()
        sample(&engine, 140, 6, .inZone, "Begin increase")
        sample(&engine, 140, 16, .increaseEffort, "Confirm increase")
        sample(&engine, 160, 17, .increaseEffort, "No instant opposite instruction")
        sample(&engine, 160, 26.999, .increaseEffort, "Hold previous instruction during confirmation")
        sample(&engine, 160, 27, .reduceEffort, "Reverse only after fresh ten seconds")
        sample(&engine, 140, 28, .reduceEffort, "Reverse direction requires its own interval")
        sample(&engine, 158, 37, .reduceEffort, "Neutral sample cancels opposite candidate")
        sample(&engine, 140, 38, .reduceEffort, "Restart opposite interval")
        sample(&engine, 140, 48, .increaseEffort, "Reverse back after confirmation")
    }

    private static func missingAndReset() {
        var warmup = ZoneDecisionEngine(target: target)
        sample(&warmup, 150, 0, .findingZone, "Start initial activation")
        warmup.heartRateUnavailable()
        sample(&warmup, 150, 5, .findingZone, "Missing data clears initial activation interval")
        sample(&warmup, 150, 10, .inZone, "Restart activation after missing data")

        var engine = activated()
        sample(&engine, 140, 6, .inZone, "Start candidate before outage")
        engine.heartRateUnavailable()
        check(engine.isCoachingActive && engine.coachingState == .findingZone, "Outage keeps activation only")
        sample(&engine, 140, 50, .findingZone, "Outage discards pending candidate time")
        sample(&engine, 140, 59.999, .findingZone, "Fresh candidate waits ten seconds")
        sample(&engine, 140, 60, .increaseEffort, "Can confirm after outage without reactivation")
        sample(&engine, 150, 61, .increaseEffort, "Start recovery before outage")
        engine.heartRateUnavailable()
        sample(&engine, 140, 70, .findingZone, "Old confirmed instruction is not restored")
        sample(&engine, 144, 79, .findingZone, "Neutral band after outage is not In Zone")
        sample(&engine, 150, 80, .inZone, "In-range HR resumes latched coaching immediately")
        engine.resetWorkout()
        check(!engine.isCoachingActive && engine.coachingState == .findingZone, "Reset clears activation")
        sample(&engine, 160, 0, .findingZone, "New workout clears timestamp watermark and instructions")
        sample(&engine, 150, 1, .findingZone, "New workout must activate again")
        sample(&engine, 150, 6, .inZone, "New workout activation")
    }

    private static func invalidAndUnorderedSamples() {
        var engine = activated()
        sample(&engine, 140, 6, .inZone, "Start candidate")
        sample(&engine, 160, 6, .inZone, "Duplicate timestamp is ignored")
        sample(&engine, 150, 4, .inZone, "Out-of-order sample cannot interrupt candidate")
        sample(&engine, 140, 16, .increaseEffort, "Ordered candidate still confirms")
        sample(&engine, .nan, 17, .findingZone, "Invalid HR is unavailable")
        check(engine.isCoachingActive, "Invalid HR preserves activation")
        sample(&engine, 140, 16, .findingZone, "Old sample after outage cannot restore instruction")
        sample(&engine, 150, 18, .inZone, "Resume valid HR")
        sample(&engine, 0, 19, .findingZone, "Zero HR is unavailable")
        sample(&engine, .infinity, 20, .findingZone, "Infinite HR is unavailable")
    }
}
