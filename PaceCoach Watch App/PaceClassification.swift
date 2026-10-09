enum PaceClassification: Equatable {
    case tooFast
    case onPace
    case tooSlow

    static func classify(
        currentPaceSecondsPerKilometer: Double?,
        fasterPaceSeconds: Double,
        slowerPaceSeconds: Double
    ) -> Self? {
        guard let currentPaceSecondsPerKilometer else { return nil }

        if currentPaceSecondsPerKilometer < fasterPaceSeconds {
            return .tooFast
        }
        if currentPaceSecondsPerKilometer > slowerPaceSeconds {
            return .tooSlow
        }
        return .onPace
    }

    var label: String {
        switch self {
        case .tooFast: "TOO FAST"
        case .onPace: "ON PACE"
        case .tooSlow: "TOO SLOW"
        }
    }
}
