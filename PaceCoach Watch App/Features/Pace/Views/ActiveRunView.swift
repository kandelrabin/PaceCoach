import SwiftUI

struct ActiveRunView: View {
    let fasterPaceSeconds: Double
    let slowerPaceSeconds: Double
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workoutManager: WorkoutManager

    init(fasterPaceSeconds: Double, slowerPaceSeconds: Double) {
        self.fasterPaceSeconds = fasterPaceSeconds
        self.slowerPaceSeconds = slowerPaceSeconds
        _workoutManager = StateObject(wrappedValue: WorkoutManager(
            fasterPaceSeconds: fasterPaceSeconds,
            slowerPaceSeconds: slowerPaceSeconds
        ))
    }

    private var coaching: (title: String, symbol: String) {
        switch workoutManager.coachingState {
        case .findingPace: return ("FINDING PACE", "hourglass")
        case .onPace: return ("ON PACE", "checkmark")
        case .speedUp: return ("SPEED UP", "arrow.up")
        case .slowDown: return ("SLOW DOWN", "arrow.down")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let paceSize = min(52, max(42, geometry.size.height * 0.26))
            let cardHeight = min(58, max(48, geometry.size.height * 0.28))

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(workoutManager.currentPaceSecondsPerKilometer.map(formattedPace) ?? "--:--")
                        .font(.system(size: paceSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(PaceTheme.primaryText)
                        .minimumScaleFactor(0.75)
                    Text("/km")
                        .font(.callout)
                        .foregroundStyle(PaceTheme.secondaryText)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

                Spacer(minLength: 4)

                Label(coaching.title, systemImage: coaching.symbol)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(PaceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: cardHeight)
                    .background(PaceTheme.accent.opacity(0.68),
                                in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("\(coaching.title)")

                if let errorMessage = workoutManager.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, 4)
                } else if workoutManager.isStarting {
                    Text("Starting workout…")
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.secondaryText)
                        .padding(.top, 4)
                }

                Spacer(minLength: 4)

                Button {
                    Task {
                        await workoutManager.endWorkout()
                        dismiss()
                    }
                } label: {
                    Label("End Run", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(PaceTheme.secondaryText)
                .disabled(workoutManager.isStarting)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaceTheme.background)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task { await workoutManager.startWorkout() }
    }
}
