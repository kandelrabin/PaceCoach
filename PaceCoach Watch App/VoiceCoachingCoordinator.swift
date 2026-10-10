import AVFoundation
import WatchKit

@MainActor
final class VoiceCoachingCoordinator {
    private static let reminderInterval: Duration = .seconds(15)

    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-GB.Malcolm")
        ?? AVSpeechSynthesisVoice(language: "en-GB")
    private var isWorkoutActive = false
    private var currentState: PaceDecisionEngine.CoachingState = .findingPace
    private var reminderTask: Task<Void, Never>?
    private var reminderGeneration = 0

    init() {
        synthesizer.usesApplicationAudioSession = false
    }

    func startWorkout() {
        endWorkout()
        isWorkoutActive = true
    }

    func endWorkout() {
        isWorkoutActive = false
        paceUnavailable()
    }

    func paceUnavailable() {
        cancelReminder()
        currentState = .findingPace
        synthesizer.stopSpeaking(at: .immediate)
    }

    func update(_ state: PaceDecisionEngine.CoachingState, activatedNow: Bool) {
        guard isWorkoutActive else { return }
        guard state != .findingPace else {
            if currentState != .findingPace { paceUnavailable() }
            return
        }

        if activatedNow {
            cancelReminder()
            currentState = .onPace
            speak(for: .onPace)
            return
        }

        guard state != currentState else { return }
        let previousState = currentState
        currentState = state
        cancelReminder()

        switch state {
        case .onPace:
            if previousState == .speedUp || previousState == .slowDown {
                speak(for: .onPace)
            }
        case .speedUp, .slowDown:
            speak(for: state)
            scheduleReminder(for: state)
        case .findingPace:
            break
        }
    }

    private func speak(for state: PaceDecisionEngine.CoachingState) {
        let phrase: String
        let haptic: WKHapticType
        switch state {
        case .onPace:
            phrase = "On pace"
            haptic = .success
        case .speedUp:
            phrase = "Speed up"
            haptic = .retry
        case .slowDown:
            phrase = "Slow down"
            haptic = .failure
        case .findingPace:
            return
        }

        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = voice
        synthesizer.speak(utterance)
        WKInterfaceDevice.current().play(haptic)
    }

    private func cancelReminder() {
        reminderTask?.cancel()
        reminderTask = nil
        reminderGeneration += 1
    }

    private func scheduleReminder(for state: PaceDecisionEngine.CoachingState) {
        let generation = reminderGeneration
        reminderTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reminderInterval)
            guard !Task.isCancelled,
                  let self,
                  self.isWorkoutActive,
                  self.reminderGeneration == generation,
                  self.currentState == state else { return }

            self.speak(for: state)
            self.scheduleReminder(for: state)
        }
    }
}
