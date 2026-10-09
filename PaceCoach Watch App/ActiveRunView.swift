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

    private var paceClassification: PaceClassification? {
        PaceClassification.classify(
            currentPaceSecondsPerKilometer: workoutManager.currentPaceSecondsPerKilometer,
            fasterPaceSeconds: fasterPaceSeconds,
            slowerPaceSeconds: slowerPaceSeconds
        )
    }

    private var coaching: (title: String, symbol: String, needsAdjustment: Bool) {
        guard workoutManager.currentPaceSecondsPerKilometer != nil else {
            return ("FINDING PACE", "location", false)
        }
        switch workoutManager.coachingDecision {
        case .tooFast: return ("SLOW DOWN", "arrow.down", true)
        case .tooSlow: return ("SPEED UP", "arrow.up", true)
        case nil: return ("HOLD PACE", "checkmark", false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    Text("CURRENT PACE")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(PaceTheme.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(workoutManager.currentPaceSecondsPerKilometer.map(formattedPace) ?? "--:--")
                            .font(.system(size: 45, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(PaceTheme.primaryText)
                            .minimumScaleFactor(0.75)
                        Text("/km")
                            .font(.caption)
                            .foregroundStyle(PaceTheme.secondaryText)
                    }
                    .lineLimit(1)
                }

                Label(coaching.title, systemImage: coaching.symbol)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(coaching.needsAdjustment ? PaceTheme.accent : PaceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(PaceTheme.accent.opacity(coaching.needsAdjustment ? 0.18 : 0.10),
                                in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Coach: \(coaching.title)")

                VStack(spacing: 2) {
                    Text("TARGET RANGE")
                        .font(.caption2.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(PaceTheme.secondaryText)
                    Text("\(formattedPace(fasterPaceSeconds))–\(formattedPace(slowerPaceSeconds)) /km")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PaceTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                if let paceClassification {
                    Text("LIVE  ·  \(paceClassification.label)")
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.secondaryText)
                }

                if let errorMessage = workoutManager.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.secondaryText)
                        .multilineTextAlignment(.center)
                } else if workoutManager.isStarting {
                    Text("Starting workout…")
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.secondaryText)
                }

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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(PaceTheme.background)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task { await workoutManager.startWorkout() }
    }
}
