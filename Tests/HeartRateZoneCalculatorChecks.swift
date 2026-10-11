import Foundation

// Run with:
// swiftc 'PaceCoach Watch App/Features/HeartRate/HeartRateZoneCalculator.swift' \
//   Tests/HeartRateZoneCalculatorChecks.swift -o /tmp/zone-checks && /tmp/zone-checks
@main
struct HeartRateZoneCalculatorChecks {
    static func main() throws {
        let zones = try HeartRateZoneCalculator.zones(restingHR: 76, estimatedMaxHR: 190)
        let expected = [(133, 144), (145, 155), (156, 167), (168, 178), (179, 190)]
        precondition(zones.count == 5)
        for (index, zone) in zones.enumerated() {
            precondition(zone.number == index + 1)
            precondition(zone.lowerBPM == expected[index].0)
            precondition(zone.upperBPM == expected[index].1)
            if index > 0 {
                precondition(zones[index - 1].upperBPM + 1 == zone.lowerBPM)
            }
        }

        let fractional = try HeartRateZoneCalculator.zones(restingHR: 70.5, estimatedMaxHR: 171)
        precondition(fractional.first?.lowerBPM == 121)
        precondition(fractional.last?.upperBPM == 171)

        precondition(fails(resting: 76, maximum: 76))
        precondition(fails(resting: 76, maximum: 75))
        precondition(fails(resting: .nan, maximum: 190))
        precondition(fails(resting: 70, maximum: 71))
        print("HeartRateZoneCalculator checks passed")
    }

    private static func fails(resting: Double, maximum: Double) -> Bool {
        (try? HeartRateZoneCalculator.zones(restingHR: resting, estimatedMaxHR: maximum)) == nil
    }
}
