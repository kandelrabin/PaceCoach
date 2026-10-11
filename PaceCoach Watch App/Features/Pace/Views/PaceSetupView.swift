import SwiftUI

struct PaceSetupView: View {
    private enum PaceField: Hashable { case faster, slower }
    private let minimumPace = 180
    private let maximumPace = 720

    @State private var fasterPaceSeconds = 5 * 60 + 50
    @State private var slowerPaceSeconds = 6 * 60 + 10
    @FocusState private var focusedPicker: PaceField?

    var body: some View {
        GeometryReader { geometry in
            let wheelHeight = min(80, max(64, geometry.size.height * 0.34))

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    paceWheel(title: "Faster", symbol: "hare.fill",
                              selection: $fasterPaceSeconds,
                              values: minimumPace..<slowerPaceSeconds,
                              field: .faster, height: wheelHeight)
                    paceWheel(title: "Slower", symbol: "tortoise.fill",
                              selection: $slowerPaceSeconds,
                              values: (fasterPaceSeconds + 1)..<(maximumPace + 1),
                              field: .slower, height: wheelHeight)
                }

                Spacer(minLength: 6)

                NavigationLink {
                    ActiveRunView(fasterPaceSeconds: Double(fasterPaceSeconds),
                                  slowerPaceSeconds: Double(slowerPaceSeconds))
                } label: {
                    Label("Start Run", systemImage: "figure.run")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PaceTheme.accent)
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaceTheme.background)
        .onAppear { focusedPicker = .faster }
    }

    private func paceWheel(title: String, symbol: String,
                           selection: Binding<Int>, values: Range<Int>,
                           field: PaceField, height: CGFloat) -> some View {
        VStack(spacing: 3) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 20)
                    .foregroundStyle(focusedPicker == field ? PaceTheme.accent : PaceTheme.primaryText)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PaceTheme.primaryText)
            }
            .frame(maxWidth: .infinity)

            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { seconds in
                    Text(formattedPace(Double(seconds)))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .tag(seconds)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .focused($focusedPicker, equals: field)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .accessibilityLabel("\(title) target pace, minutes per kilometre")
        }
        .frame(maxWidth: .infinity)
    }
}

func formattedPace(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds.rounded())
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
