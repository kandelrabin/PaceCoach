import SwiftUI

struct ActiveZoneRunView: View {
    let target: TargetHeartRateZone
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workoutManager: WorkoutManager
    @State private var isEnding = false
    @State private var startupFinished = false

    init(target: TargetHeartRateZone) {
        self.target = target
        _workoutManager = StateObject(wrappedValue: WorkoutManager(targetZone: target))
    }

    var body: some View {
        GeometryReader { geometry in
            let heartRateSize = min(64, max(48, geometry.size.height * 0.34))
            let cardHeight = min(68, max(60, geometry.size.height * 0.32))

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(workoutManager.currentHeartRateBPM.map {
                        $0.formatted(.number.precision(.fractionLength(0)))
                    } ?? "--")
                        .font(.system(size: heartRateSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(PaceTheme.primaryText)
                        .minimumScaleFactor(0.75)

                    Text("BPM")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(PaceTheme.secondaryText)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .accessibilityElement(children: .combine)

                Spacer(minLength: 4)

                Text(coachingTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(PaceTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: cardHeight)
                    .background(PaceTheme.accent.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))

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
                    isEnding = true
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
                .disabled(!startupFinished || workoutManager.isStarting || isEnding)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaceTheme.background)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await workoutManager.startWorkout()
            startupFinished = true
        }
    }

    private var coachingTitle: String {
        switch workoutManager.zoneCoachingState {
        case .findingZone: "FINDING ZONE"
        case .inZone: "IN ZONE"
        case .increaseEffort: "INCREASE EFFORT"
        case .reduceEffort: "REDUCE EFFORT"
        }
    }
}
