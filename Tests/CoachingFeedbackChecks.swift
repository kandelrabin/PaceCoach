import Foundation

// Run with:
// swiftc 'PaceCoach Watch App/Coaching/VoiceCoachingCoordinator.swift' \
//   Tests/CoachingFeedbackChecks.swift -o /tmp/coaching-feedback-checks \
//   && /tmp/coaching-feedback-checks
@main
struct CoachingFeedbackChecks {
    private static let origin = ContinuousClock().now
    private static var assertions = 0

    static func main() {
        zoneEventsAndReminders()
        unavailableAndLifecycle()
        paceRegression()
        print("Coaching feedback checks passed (\(assertions) assertions)")
    }

    private static func instant(_ seconds: Int) -> ContinuousClock.Instant {
        origin.advanced(by: .seconds(seconds))
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        assertions += 1
    }

    private static func event(_ event: CoachingFeedbackEvent?,
                              _ phrase: String, _ haptic: CoachingFeedbackHaptic,
                              _ message: String) {
        check(event == .init(phrase: phrase, haptic: haptic), message)
    }

    private static func zoneEventsAndReminders() {
        var policy = CoachingFeedbackPolicy()
        policy.startWorkout(mode: .zone)
        check(policy.update(.finding, activatedNow: false, at: instant(0)) == nil,
              "Finding Zone is silent")
        check(policy.reminderIfDue(at: instant(30)) == nil, "Finding Zone has no reminder")
        event(policy.update(.steady, activatedNow: true, at: instant(31)),
              "In zone", .success, "First activation announces In Zone")
        check(policy.update(.steady, activatedNow: false, at: instant(32)) == nil,
              "Duplicate In Zone sample is silent")
        check(policy.reminderIfDue(at: instant(60)) == nil, "In Zone never repeats")

        event(policy.update(.increase, activatedNow: false, at: instant(61)),
              "Increase effort", .retry, "Confirmed low HR gives voice and retry")
        check(policy.reminderIfDue(at: instant(75)) == nil, "No early increase reminder")
        event(policy.reminderIfDue(at: instant(76)), "Increase effort", .retry,
              "Increase reminder at 15 seconds includes haptic")
        check(policy.reminderIfDue(at: instant(90)) == nil,
              "Increase interval restarts from last delivered cue")
        event(policy.reminderIfDue(at: instant(91)), "Increase effort", .retry,
              "Increase reminder repeats from last cue")

        event(policy.update(.reduce, activatedNow: false, at: instant(92)),
              "Reduce effort", .failure, "Confirmed direction change replaces cue")
        check(policy.reminderIfDue(at: instant(106)) == nil,
              "Old increase reminder cannot survive a direction change")
        event(policy.reminderIfDue(at: instant(107)), "Reduce effort", .failure,
              "Reduce reminder at 15 seconds includes haptic")
        event(policy.update(.steady, activatedNow: false, at: instant(108)),
              "In zone", .success, "Recovery announces once with success")
        check(policy.update(.steady, activatedNow: false, at: instant(109)) == nil,
              "Recovery is not duplicated")
        check(policy.reminderIfDue(at: instant(140)) == nil,
              "Recovery cancels directional reminders")

        event(policy.update(.reduce, activatedNow: false, at: instant(141)),
              "Reduce effort", .failure, "Reduce can be entered again")
        event(policy.update(.steady, activatedNow: false, at: instant(142)),
              "In zone", .success, "Recovery from Reduce also announces")
    }

    private static func unavailableAndLifecycle() {
        var policy = CoachingFeedbackPolicy()
        policy.startWorkout(mode: .zone)
        event(policy.update(.steady, activatedNow: true, at: instant(0)),
              "In zone", .success, "Zone workout activates")
        event(policy.update(.increase, activatedNow: false, at: instant(1)),
              "Increase effort", .retry, "Initial direction is delivered")
        policy.unavailable()
        check(policy.currentState == .finding && policy.lastDeliveredAt == nil,
              "Missing HR clears directional feedback and reminder time")
        check(policy.reminderIfDue(at: instant(100)) == nil,
              "Missing HR produces no reminder")
        check(policy.update(.finding, activatedNow: false, at: instant(101)) == nil,
              "Missing HR remains silent")
        check(policy.update(.steady, activatedNow: false, at: instant(102)) == nil,
              "Resumed in-range HR does not replay an obsolete cue")
        check(policy.reminderIfDue(at: instant(200)) == nil,
              "Resumption has no old direction reminder")
        event(policy.update(.reduce, activatedNow: false, at: instant(201)),
              "Reduce effort", .failure, "Fresh valid decision drives feedback")
        policy.endWorkout()
        check(policy.mode == nil && policy.currentState == .finding && policy.lastDeliveredAt == nil,
              "Workout end resets feedback and scheduling")
        check(policy.update(.increase, activatedNow: false, at: instant(202)) == nil,
              "No transition feedback after end")
        check(policy.reminderIfDue(at: instant(300)) == nil,
              "No reminder after end")
        policy.startWorkout(mode: .zone)
        check(policy.currentState == .finding, "New workout begins at Finding Zone")
        check(policy.update(.finding, activatedNow: false, at: instant(301)) == nil,
              "New workout Finding Zone is silent")
        event(policy.update(.steady, activatedNow: true, at: instant(306)),
              "In zone", .success, "New workout announces first activation")
    }

    private static func paceRegression() {
        var policy = CoachingFeedbackPolicy()
        policy.startWorkout(mode: .pace)
        check(policy.update(.finding, activatedNow: false, at: instant(0)) == nil,
              "Finding Pace remains silent")
        event(policy.update(.steady, activatedNow: true, at: instant(3)),
              "On pace", .success, "Pace activation is unchanged")
        event(policy.update(.increase, activatedNow: false, at: instant(10)),
              "Speed up", .retry, "Pace increase mapping is unchanged")
        event(policy.reminderIfDue(at: instant(25)),
              "Speed up", .retry, "Pace directional reminder is unchanged")
        event(policy.update(.reduce, activatedNow: false, at: instant(26)),
              "Slow down", .failure, "Pace reduce mapping is unchanged")
        event(policy.reminderIfDue(at: instant(41)),
              "Slow down", .failure, "Pace reduce reminder is unchanged")
        event(policy.update(.steady, activatedNow: false, at: instant(42)),
              "On pace", .success, "Pace recovery is unchanged")
        check(policy.reminderIfDue(at: instant(100)) == nil,
              "On Pace does not repeat")
        policy.unavailable()
        check(policy.update(.steady, activatedNow: false, at: instant(101)) == nil,
              "Pace resumption does not replay obsolete coaching")
        policy.endWorkout()
        check(policy.reminderIfDue(at: instant(120)) == nil,
              "Pace workout end cancels reminders")
    }
}
