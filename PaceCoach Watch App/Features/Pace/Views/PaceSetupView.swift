import SwiftUI

struct PaceSetupView: View {
    private enum PaceField: Hashable { case faster, slower }
    private let minimumPace = 180
    private let maximumPace = 720
    private let minimumSeparation = 10

    @State private var fasterPaceSeconds = 5 * 60 + 50
    @State private var slowerPaceSeconds = 6 * 60 + 10
    @FocusState private var focusedPicker: PaceField?

    private var fasterPaceSelection: Binding<Int> {
        Binding(
            get: { fasterPaceSeconds },
            set: { fasterPaceSeconds = min(max($0, minimumPace), slowerPaceSeconds - minimumSeparation) }
        )
    }

    private var slowerPaceSelection: Binding<Int> {
        Binding(
            get: { slowerPaceSeconds },
            set: { slowerPaceSeconds = max(min($0, maximumPace), fasterPaceSeconds + minimumSeparation) }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let wheelHeight = min(80, max(64, geometry.size.height * 0.34))

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    PaceWheel(title: "Faster", symbol: "hare.fill",
                              selection: fasterPaceSelection,
                              values: minimumPace..<(slowerPaceSeconds - minimumSeparation + 1),
                              field: .faster, height: wheelHeight,
                              focus: $focusedPicker)
                        .id(slowerPaceSeconds)
                    PaceWheel(title: "Slower", symbol: "tortoise.fill",
                              selection: slowerPaceSelection,
                              values: (fasterPaceSeconds + minimumSeparation)..<(maximumPace + 1),
                              field: .slower, height: wheelHeight,
                              focus: $focusedPicker)
                        .id(fasterPaceSeconds)
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

    private struct PaceWheel: View {
        let title: String
        let symbol: String
        let selection: Binding<Int>
        let values: Range<Int>
        let field: PaceField
        let height: CGFloat
        let focus: FocusState<PaceField?>.Binding
        @State private var wheelSelection: Int

        init(title: String, symbol: String, selection: Binding<Int>,
             values: Range<Int>, field: PaceField, height: CGFloat,
             focus: FocusState<PaceField?>.Binding) {
            self.title = title
            self.symbol = symbol
            self.selection = selection
            self.values = values
            self.field = field
            self.height = height
            self.focus = focus
            _wheelSelection = State(initialValue: selection.wrappedValue)
        }

        var body: some View {
            VStack(spacing: 3) {
                VStack(spacing: 2) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(height: 20)
                        .foregroundStyle(focus.wrappedValue == field ? PaceTheme.accent : PaceTheme.primaryText)
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PaceTheme.primaryText)
                }
                .frame(maxWidth: .infinity)

                Picker(title, selection: $wheelSelection) {
                    ForEach(values, id: \.self) { seconds in
                        Text(formattedPace(Double(seconds)))
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .tag(seconds)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .focused(focus, equals: field)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .accessibilityLabel("\(title) target pace, minutes per kilometre")
                .onChange(of: wheelSelection) { _, newValue in
                    selection.wrappedValue = newValue
                    if wheelSelection != selection.wrappedValue {
                        wheelSelection = selection.wrappedValue
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

func formattedPace(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds.rounded())
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
