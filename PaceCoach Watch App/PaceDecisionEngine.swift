import Foundation

struct PaceDecisionEngine {
    enum Decision: Equatable {
        case tooFast
        case tooSlow
    }

    private static let smoothingWindow: TimeInterval = 5
    private static let entryTolerance: Double = 5
    private static let confirmationDuration: TimeInterval = 8
    private static let recoveryDuration: TimeInterval = 3

    private let fasterPaceSeconds: Double
    private let slowerPaceSeconds: Double
    private var samples: [(date: Date, pace: Double)] = []
    private var lastSampleDate: Date?
    private var pendingDecision: Decision?
    private var pendingSince: Date?
    private var recoverySince: Date?

    private(set) var coachingPaceSecondsPerKilometer: Double?
    private(set) var confirmedDecision: Decision?

    init(fasterPaceSeconds: Double, slowerPaceSeconds: Double) {
        self.fasterPaceSeconds = fasterPaceSeconds
        self.slowerPaceSeconds = slowerPaceSeconds
    }

    @discardableResult
    mutating func addSample(paceSecondsPerKilometer: Double, at date: Date) -> Decision? {
        guard paceSecondsPerKilometer.isFinite,
              paceSecondsPerKilometer > 0,
              lastSampleDate.map({ date > $0 }) ?? true else {
            return confirmedDecision
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

        return confirmedDecision
    }

    mutating func reset() {
        samples.removeAll()
        lastSampleDate = nil
        pendingDecision = nil
        pendingSince = nil
        recoverySince = nil
        coachingPaceSecondsPerKilometer = nil
        confirmedDecision = nil
    }
}
