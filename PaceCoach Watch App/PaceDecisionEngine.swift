import Foundation

struct PaceDecisionEngine {
    enum CoachingState: Equatable {
        case findingPace
        case onPace
        case speedUp
        case slowDown
    }

    enum Decision: Equatable {
        case tooFast
        case tooSlow
    }

    private static let activationDuration: TimeInterval = 3
    private static let smoothingWindow: TimeInterval = 5
    private static let entryTolerance: Double = 5
    private static let confirmationDuration: TimeInterval = 8
    private static let recoveryDuration: TimeInterval = 3

    private let fasterPaceSeconds: Double
    private let slowerPaceSeconds: Double
    private var samples: [(date: Date, pace: Double)] = []
    private var lastSampleDate: Date?
    private var activationSince: Date?
    private var pendingDecision: Decision?
    private var pendingSince: Date?
    private var recoverySince: Date?

    private(set) var coachingPaceSecondsPerKilometer: Double?
    private(set) var confirmedDecision: Decision?
    private(set) var isCoachingActive = false
    private(set) var coachingState: CoachingState = .findingPace

    init(fasterPaceSeconds: Double, slowerPaceSeconds: Double) {
        self.fasterPaceSeconds = fasterPaceSeconds
        self.slowerPaceSeconds = slowerPaceSeconds
    }

    @discardableResult
    mutating func addSample(paceSecondsPerKilometer: Double, at date: Date) -> CoachingState {
        guard paceSecondsPerKilometer.isFinite, paceSecondsPerKilometer > 0 else {
            clearTransientPace()
            return coachingState
        }
        guard lastSampleDate.map({ date > $0 }) ?? true else { return coachingState }

        if !isCoachingActive,
           let lastSampleDate,
           date.timeIntervalSince(lastSampleDate) > Self.activationDuration {
            activationSince = nil
        }

        lastSampleDate = date
        samples.append((date, paceSecondsPerKilometer))
        samples.removeAll { date.timeIntervalSince($0.date) > Self.smoothingWindow }

        let sortedPaces = samples.map(\.pace).sorted()
        let middle = sortedPaces.count / 2
        let coachingPace: Double
        if sortedPaces.count.isMultiple(of: 2) {
            coachingPace = (sortedPaces[middle - 1] + sortedPaces[middle]) / 2
        } else {
            coachingPace = sortedPaces[middle]
        }
        coachingPaceSecondsPerKilometer = coachingPace

        if !isCoachingActive {
            if paceSecondsPerKilometer >= fasterPaceSeconds && paceSecondsPerKilometer <= slowerPaceSeconds {
                if activationSince == nil { activationSince = date }
                if let activationSince,
                   date.timeIntervalSince(activationSince) >= Self.activationDuration {
                    isCoachingActive = true
                    self.activationSince = nil
                    coachingState = .onPace
                }
            } else {
                activationSince = nil
            }
            return coachingState
        }

        let candidate: Decision?
        if coachingPace < fasterPaceSeconds - Self.entryTolerance {
            candidate = .tooFast
        } else if coachingPace > slowerPaceSeconds + Self.entryTolerance {
            candidate = .tooSlow
        } else {
            candidate = nil
        }

        // A confirmed direction needs no new entry timer. An opposite direction does.
        let newPendingDecision = candidate == confirmedDecision ? nil : candidate
        if newPendingDecision != pendingDecision {
            pendingDecision = newPendingDecision
            pendingSince = newPendingDecision == nil ? nil : date
        }

        if let pendingDecision, let pendingSince,
           date.timeIntervalSince(pendingSince) >= Self.confirmationDuration {
            confirmedDecision = pendingDecision
            self.pendingDecision = nil
            self.pendingSince = nil
            recoverySince = nil
        } else if confirmedDecision != nil {
            if coachingPace >= fasterPaceSeconds && coachingPace <= slowerPaceSeconds {
                if recoverySince == nil { recoverySince = date }
                if let recoverySince,
                   date.timeIntervalSince(recoverySince) >= Self.recoveryDuration {
                    confirmedDecision = nil
                    self.recoverySince = nil
                }
            } else {
                recoverySince = nil
            }
        }

        switch confirmedDecision {
        case .tooFast: coachingState = .slowDown
        case .tooSlow: coachingState = .speedUp
        case nil: coachingState = .onPace
        }
        return coachingState
    }

    mutating func clearTransientPace() {
        samples.removeAll()
        lastSampleDate = nil
        activationSince = nil
        pendingDecision = nil
        pendingSince = nil
        recoverySince = nil
        coachingPaceSecondsPerKilometer = nil
        confirmedDecision = nil
        coachingState = .findingPace
    }

    mutating func resetWorkout() {
        clearTransientPace()
        isCoachingActive = false
    }
}
