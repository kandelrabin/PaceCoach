import Foundation

// Both decision engines feed this shared vocabulary; their decisions remain separate.
enum CoachingFeedbackMode { case pace, zone }
enum CoachingFeedbackState: Equatable { case finding, steady, increase, reduce }
enum CoachingFeedbackHaptic: Equatable { case success, retry, failure }

struct CoachingFeedbackEvent: Equatable {
    let phrase: String
    let haptic: CoachingFeedbackHaptic
}

// Pure feedback policy, driven by the coordinator's single reminder task.
struct CoachingFeedbackPolicy {
    static let reminderInterval: Duration = .seconds(15)
    private(set) var mode: CoachingFeedbackMode?
    private(set) var currentState: CoachingFeedbackState = .finding
    private(set) var lastDeliveredAt: ContinuousClock.Instant?

    mutating func startWorkout(mode: CoachingFeedbackMode) {
        endWorkout()
        self.mode = mode
    }

    mutating func endWorkout() {
        mode = nil
        unavailable()
    }

    mutating func unavailable() {
        currentState = .finding
        lastDeliveredAt = nil
    }

    mutating func update(_ state: CoachingFeedbackState, activatedNow: Bool,
                         at now: ContinuousClock.Instant) -> CoachingFeedbackEvent? {
        guard mode != nil else { return nil }
        guard state != .finding else {
            unavailable()
            return nil
        }
        if activatedNow {
            currentState = .steady
            return deliver(.steady, at: now)
        }
        guard state != currentState else { return nil }
        let previousState = currentState
        currentState = state
        lastDeliveredAt = nil
        switch state {
        case .steady:
            // Returning from unavailable data does not replay the previous cue.
            return previousState == .increase || previousState == .reduce
                ? deliver(.steady, at: now) : nil
        case .increase, .reduce:
            return deliver(state, at: now)
        case .finding:
            return nil
        }
    }

    mutating func reminderIfDue(at now: ContinuousClock.Instant) -> CoachingFeedbackEvent? {
        guard mode != nil,
              currentState == .increase || currentState == .reduce,
              let lastDeliveredAt,
              lastDeliveredAt.duration(to: now) >= Self.reminderInterval else { return nil }
        return deliver(currentState, at: now)
    }

    private mutating func deliver(_ state: CoachingFeedbackState,
                                  at now: ContinuousClock.Instant) -> CoachingFeedbackEvent? {
        guard let mode else { return nil }
        let event: CoachingFeedbackEvent
        switch (mode, state) {
        case (.pace, .steady): event = .init(phrase: "On pace", haptic: .success)
        case (.pace, .increase): event = .init(phrase: "Speed up", haptic: .retry)
        case (.pace, .reduce): event = .init(phrase: "Slow down", haptic: .failure)
        case (.zone, .steady): event = .init(phrase: "In zone", haptic: .success)
        case (.zone, .increase): event = .init(phrase: "Increase effort", haptic: .retry)
        case (.zone, .reduce): event = .init(phrase: "Reduce effort", haptic: .failure)
        case (_, .finding): return nil
        }
        lastDeliveredAt = now
        return event
    }
}

#if os(watchOS)
import AVFoundation
import WatchKit

@MainActor
final class VoiceCoachingCoordinator {
    private var synthesizer: AVSpeechSynthesizer?
    private var voice: AVSpeechSynthesisVoice?
    private let clock = ContinuousClock()
    private var feedback = CoachingFeedbackPolicy()
    private var reminderTask: Task<Void, Never>?
    private var reminderGeneration = 0

    func prewarmAudio() {
        _ = preparedSynthesizer()
    }

    func startWorkout(mode: CoachingFeedbackMode) {
        endWorkout()
        feedback.startWorkout(mode: mode)
    }

    func endWorkout() {
        cancelReminder()
        feedback.endWorkout()
        synthesizer?.stopSpeaking(at: .immediate)
    }

    func paceUnavailable() { feedbackUnavailable() }
    func heartRateUnavailable() { feedbackUnavailable() }

    private func feedbackUnavailable() {
        cancelReminder()
        feedback.unavailable()
        synthesizer?.stopSpeaking(at: .immediate)
    }

    func update(_ state: PaceDecisionEngine.CoachingState, activatedNow: Bool) {
        guard feedback.mode == .pace else { return }
        let mapped: CoachingFeedbackState
        switch state {
        case .findingPace: mapped = .finding
        case .onPace: mapped = .steady
        case .speedUp: mapped = .increase
        case .slowDown: mapped = .reduce
        }
        update(mapped, activatedNow: activatedNow)
    }

    func update(_ state: ZoneDecisionEngine.CoachingState, activatedNow: Bool) {
        guard feedback.mode == .zone else { return }
        let mapped: CoachingFeedbackState
        switch state {
        case .findingZone: mapped = .finding
        case .inZone: mapped = .steady
        case .increaseEffort: mapped = .increase
        case .reduceEffort: mapped = .reduce
        }
        update(mapped, activatedNow: activatedNow)
    }

    private func update(_ state: CoachingFeedbackState, activatedNow: Bool) {
        let previousState = feedback.currentState
        let event = feedback.update(state, activatedNow: activatedNow, at: clock.now)
        guard state != previousState || activatedNow else { return }
        cancelReminder()
        if let event { speak(event) }
        if state == .increase || state == .reduce { scheduleReminder(for: state) }
    }

    private func speak(_ event: CoachingFeedbackEvent) {
        guard feedback.mode != nil else { return }
        let synthesizer = preparedSynthesizer()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: event.phrase)
        utterance.voice = voice
        synthesizer.speak(utterance)
        let haptic: WKHapticType
        switch event.haptic {
        case .success: haptic = .success
        case .retry: haptic = .retry
        case .failure: haptic = .failure
        }
        WKInterfaceDevice.current().play(haptic)
    }

    private func preparedSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = false
        voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-GB.Malcolm")
            ?? AVSpeechSynthesisVoice(language: "en-GB")
        self.synthesizer = synthesizer
        return synthesizer
    }

    private func cancelReminder() {
        reminderTask?.cancel()
        reminderTask = nil
        reminderGeneration += 1
    }

    private func scheduleReminder(for state: CoachingFeedbackState) {
        let generation = reminderGeneration
        reminderTask = Task { [weak self] in
            try? await Task.sleep(for: CoachingFeedbackPolicy.reminderInterval)
            guard !Task.isCancelled,
                  let self,
                  self.feedback.mode != nil,
                  self.reminderGeneration == generation,
                  self.feedback.currentState == state else { return }
            if let event = self.feedback.reminderIfDue(at: self.clock.now) {
                self.speak(event)
            }
            self.scheduleReminder(for: state)
        }
    }
}
#endif
