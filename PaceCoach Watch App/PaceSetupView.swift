import SwiftUI

struct PaceSetupView: View {
    @State private var fasterPaceSeconds = 5.0 * 60 + 50
    @State private var slowerPaceSeconds = 6.0 * 60 + 10

    var body: some View {
        VStack(spacing: 5) {
            Text("Target Pace")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(formattedPace(fasterPaceSeconds)) – \(formattedPace(slowerPaceSeconds))")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                Text("min/km")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Target pace range")

            VStack(spacing: 4) {
                paceLink(title: "Faster", value: fasterPaceSeconds) {
                    PaceAdjustmentView(title: "Faster", paceSeconds: $fasterPaceSeconds)
                }
                paceLink(title: "Slower", value: slowerPaceSeconds) {
                    PaceAdjustmentView(title: "Slower", paceSeconds: $slowerPaceSeconds)
                }
            }

            NavigationLink {
                ActiveRunView(
                    fasterPaceSeconds: fasterPaceSeconds,
                    slowerPaceSeconds: slowerPaceSeconds
                )
            } label: {
                Text("Start Run")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func paceLink<Destination: View>(
        title: String,
        value: Double,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 4)
                Text(formattedPace(value))
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PaceAdjustmentView: View {
    let title: String
    @Binding var paceSeconds: Double

    var body: some View {
        VStack(spacing: 4) {
            Text("min/km")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formattedPace(paceSeconds))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .focusable()
                .digitalCrownRotation(
                    $paceSeconds,
                    from: 180.0,
                    through: 720.0,
                    by: 1.0,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: false
                )

            Text("Turn Digital Crown")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

func formattedPace(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds.rounded())
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
