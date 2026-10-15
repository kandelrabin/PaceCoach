import SwiftUI

struct StravaStatusView: View {
    @ObservedObject var model: StravaStatusModel

    private var presentation: StravaStatusPresentation { model.presentation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                setupStatus

                if presentation.isUploadStatusUnavailable {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Upload status unavailable", systemImage: "exclamationmark.circle")
                            .font(.headline)
                        Text("Some saved statuses could not be read.")
                            .font(.footnote)
                            .foregroundStyle(PaceTheme.secondaryText)
                    }
                } else if presentation.runs.isEmpty {
                    Text("No uploads yet")
                        .font(.headline)
                }

                runSection("Needs attention", runs: presentation.attentionRuns)

                if let run = presentation.recentUpload {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent upload")
                            .font(.caption.bold())
                            .foregroundStyle(PaceTheme.secondaryText)
                        Label(run.status.title, systemImage: run.status.symbol)
                            .font(.body.weight(.semibold))
                        runDate(run)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(PaceTheme.background)
        .navigationTitle("Strava")
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch presentation.credentials {
        case .notSetUp:
            VStack(alignment: .leading, spacing: 6) {
                Label("Set up Strava on iPhone", systemImage: "iphone")
                    .font(.headline)
                Text("Connect Strava in PaceCoach on iPhone, then set up this Watch.")
                    .font(.footnote)
                    .foregroundStyle(PaceTheme.secondaryText)
            }
        case .setUp:
            VStack(alignment: .leading, spacing: 3) {
                Label("Set up on this Watch", systemImage: "checkmark.circle")
                    .font(.body.weight(.semibold))
                Text("Runs upload automatically")
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.secondaryText)
            }
        case .unavailable:
            VStack(alignment: .leading, spacing: 6) {
                Label("Strava setup unavailable", systemImage: "exclamationmark.circle")
                    .font(.headline)
                Text("Try reopening PaceCoach after unlocking your Watch.")
                    .font(.footnote)
                    .foregroundStyle(PaceTheme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func runSection(_ title: String, runs: [StravaStatusPresentation.Run]) -> some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(PaceTheme.secondaryText)
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        runDate(run)
                        Label(run.status.title, systemImage: run.status.symbol)
                            .font(.body.weight(.semibold))
                        if let explanation = run.status.explanation {
                            Text(explanation)
                                .font(.footnote)
                                .foregroundStyle(PaceTheme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(PaceTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func runDate(_ run: StravaStatusPresentation.Run) -> some View {
        Text(run.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Date unavailable")
            .font(.caption2)
            .foregroundStyle(PaceTheme.secondaryText)
    }
}
