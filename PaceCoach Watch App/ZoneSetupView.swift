import SwiftUI

struct ZoneSetupView: View {
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(HeartRateProfile)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Target Zone")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(PaceTheme.primaryText)

                switch state {
                case .loading:
                    ProgressView("Loading HR data…")
                case .failed(let message):
                    Text("Could not load HR data")
                        .foregroundStyle(PaceTheme.primaryText)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.secondaryText)
                    Button("Retry") { Task { await loadProfile() } }
                case .loaded(let profile):
                    Text("HealthKit diagnostic · Workouts \(HeartRateProfileService.workoutHistoryDays)d · Resting \(HeartRateProfileService.restingHistoryDays)d")
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.secondaryText)

                    metric("Resting HR query", value: queryStatus(profile.restingStatus))
                    metric("Recent resting HR", value: profile.restingReadings.first.map { bpm($0.bpm) } ?? "Unavailable")
                    ForEach(profile.restingReadings.prefix(3), id: \.id) { reading in
                        Text("\(reading.date.formatted(date: .abbreviated, time: .omitted)): \(bpm(reading.bpm))")
                            .font(.caption2)
                            .foregroundStyle(PaceTheme.secondaryText)
                    }
                    metric("Running workout query", value: queryStatus(profile.runningWorkoutStatus))
                    metric("Running workouts found", value: "\(profile.runningWorkouts.count)")
                    metric("Workout HR query", value: queryStatus(profile.workoutHeartRateStatus))
                    metric("Workouts with HR", value: "\(profile.workoutsWithHeartRate)")
                    metric("Highest observed HR", value: profile.highestObservedWorkoutBPM.map(bpm) ?? "Unavailable")
                    if profile.workoutHeartRateQueryIssues > 0 {
                        metric("Workout HR query issues", value: "\(profile.workoutHeartRateQueryIssues)")
                    }
                    metric("HR sample objects", value: "\(profile.heartRateSampleObjects)")
                    metric("Series objects", value: "\(profile.heartRateSeriesObjects)")
                    metric("Stored HR quantities", value: "\(profile.storedHeartRateQuantities)")

                    ForEach(profile.runningWorkouts.prefix(3), id: \.id) { workout in
                        Text("\(workout.date.formatted(date: .abbreviated, time: .omitted)) · \(workout.source): \(workout.highestObservedBPM.map(bpm) ?? "No HR")")
                            .font(.caption2)
                            .foregroundStyle(PaceTheme.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(PaceTheme.background)
        .task { await loadProfile() }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(PaceTheme.secondaryText)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(PaceTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func queryStatus(_ status: HeartRateProfile.QueryStatus) -> String {
        switch status {
        case .loaded: "Loaded"
        case .noData: "No data"
        case .error(let message): "Error: \(message)"
        case .notRun(let reason): "Not run: \(reason)"
        }
    }

    private func bpm(_ value: Double) -> String {
        "\(Int(value.rounded())) BPM"
    }

    private func loadProfile() async {
        state = .loading
        do {
            let profile = try await HeartRateProfileService().load()
            guard !Task.isCancelled else { return }
            state = .loaded(profile)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
