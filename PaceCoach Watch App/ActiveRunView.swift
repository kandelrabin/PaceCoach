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

    private var coachingLabel: String {
        guard workoutManager.currentPaceSecondsPerKilometer != nil else { return "--" }
        switch workoutManager.coachingDecision {
        case .tooFast: return "SLOW DOWN"
        case .tooSlow: return "SPEED UP"
        case nil: return "NO CHANGE"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(workoutManager.currentPaceSecondsPerKilometer.map(formattedPace) ?? "--:--")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/km")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Current Pace")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let paceClassification {
                Text("LIVE: \(paceClassification.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("COACH: \(coachingLabel)")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let errorMessage = workoutManager.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if workoutManager.isStarting {
                Text("Starting Workout")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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
                Task {
                    await workoutManager.endWorkout()
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
            .disabled(workoutManager.isStarting)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await workoutManager.startWorkout()
        }
    }
}
