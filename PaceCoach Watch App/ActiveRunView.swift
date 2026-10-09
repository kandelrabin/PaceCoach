import SwiftUI

struct ActiveRunView: View {
    let fasterPaceSeconds: Double
    let slowerPaceSeconds: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("--:--")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/km")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Current Pace")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            VStack(spacing: 2) {
                Text("TARGET RANGE")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(formattedPace(fasterPaceSeconds))–\(formattedPace(slowerPaceSeconds)) min/km")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Button("End Run") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
}
