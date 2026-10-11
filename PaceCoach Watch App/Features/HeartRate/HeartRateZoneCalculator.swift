import Foundation

struct TargetHeartRateZone: Hashable, Identifiable {
    let number: Int
    let lowerBPM: Int
    let upperBPM: Int

    var id: Int { number }
}

enum HeartRateZoneCalculator {
    enum CalculationError: LocalizedError {
        case invalidProfile
        case insufficientRange

        var errorDescription: String? {
            switch self {
            case .invalidProfile:
                "Resting HR and estimated max HR must be valid, with max HR higher than resting HR."
            case .insufficientRange:
                "This heart-rate range is too narrow to form five distinct BPM zones."
            }
        }
    }

    static func zones(restingHR: Double, estimatedMaxHR: Double) throws -> [TargetHeartRateZone] {
        guard restingHR.isFinite, estimatedMaxHR.isFinite,
              restingHR > 0, estimatedMaxHR > restingHR,
              estimatedMaxHR <= 1000 else {
            throw CalculationError.invalidProfile
        }

        let reserve = estimatedMaxHR - restingHR
        let percentages = [50.0, 60.0, 70.0, 80.0, 90.0]

        // Each HRR band is lower-inclusive and upper-exclusive, except Zone 5,
        // which includes 100%. For integer BPM, ceil each real lower threshold;
        // the prior zone ends one BPM below the next zone's lower bound.
        let lowerBounds = percentages.map { percentage in
            Int(ceil(restingHR + percentage / 100 * reserve))
        }
        let maximumBPM = Int(floor(estimatedMaxHR))
        let zones = lowerBounds.indices.map { index in
            TargetHeartRateZone(
                number: index + 1,
                lowerBPM: lowerBounds[index],
                upperBPM: index + 1 < lowerBounds.count
                    ? lowerBounds[index + 1] - 1
                    : maximumBPM
            )
        }

        guard zones.allSatisfy({ $0.lowerBPM <= $0.upperBPM }) else {
            throw CalculationError.insufficientRange
        }
        return zones
    }
}
