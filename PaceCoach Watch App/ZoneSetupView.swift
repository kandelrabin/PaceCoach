import SwiftUI

struct ZoneSetupView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: LoadState = .loading
    @State private var loadAttempt: UUID?
    @State private var authorizationAttempt: UUID?
    @State private var authorizationMessage: String?
    @State private var isRequestingAccess = false

    private static let setupWaitSeconds = 30

    private enum LoadState {
        case loading
        case loaded(HeartRateProfile)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch state {
                case .loading:
                    ProgressView("Loading heart rate…")
                case .failed(let message):
                    unavailable(message)
                case .loaded(let profile):
                    if let resting = profile.representativeRestingHR,
                       let maximum = profile.estimatedMaxHR {
                        if resting.isSparse {
                            unavailable("Need resting HR values from at least 3 days in the last 30 days.")
                        } else if let zones = try? HeartRateZoneCalculator.zones(
                            restingHR: resting.bpm,
                            estimatedMaxHR: maximum.bpm
                        ) {
                            ForEach(zones) { zone in
                                NavigationLink {
                                    ZoneDetailView(target: zone)
                                } label: {
                                    zoneRow(zone)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            unavailable("The available heart-rate profile cannot form five BPM zones.")
                        }
                    } else {
                        unavailable(missingDataMessage(for: profile))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(PaceTheme.background)
        .task { await loadProfile() }
        .onDisappear {
            // The system request may outlive this view. Do not reload an
            // offscreen setup view when its permission sheet later completes.
            authorizationAttempt = nil
            isRequestingAccess = false
        }
    }

    private func zoneRow(_ zone: TargetHeartRateZone) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Zone \(zone.number)")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(PaceTheme.primaryText)
                Text(zoneDescription(zone.number))
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.secondaryText)
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(PaceTheme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaceTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zones unavailable")
                .font(.body.weight(.semibold))
                .foregroundStyle(PaceTheme.primaryText)
            Text(message)
                .font(.caption2)
                .foregroundStyle(PaceTheme.secondaryText)
            Button("Retry") { Task { await loadProfile() } }
                .tint(PaceTheme.accent)
            Text("This profile uses heart rate, resting heart rate and running workout history. Missing data may also reflect Health access settings.")
                .font(.caption2)
                .foregroundStyle(PaceTheme.secondaryText)
            Button("Request Health Access") {
                Task { await requestHealthAccess() }
            }
            .tint(PaceTheme.accent)
            .disabled(isRequestingAccess || scenePhase != .active)
            if isRequestingAccess {
                ProgressView("Waiting for HealthKit…")
            }
            if let authorizationMessage {
                Text(authorizationMessage)
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.secondaryText)
            }
        }
    }

    private func requestHealthAccess() async {
        guard scenePhase == .active, !isRequestingAccess else { return }
        let attempt = UUID()
        authorizationAttempt = attempt
        authorizationMessage = nil
        isRequestingAccess = true

        // This bounds only the UI wait, not HealthKit's permission sheet. A
        // normal interaction may finish later; the coordinator retains the
        // native request so a timeout never allows overlapping permission sheets.
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(Self.setupWaitSeconds))
            } catch { return }
            guard authorizationAttempt == attempt else { return }
            authorizationAttempt = nil
            isRequestingAccess = false
            authorizationMessage = "HealthKit has not finished. Complete the permission sheet if shown, or check Health permissions. Retry can load available data."
            log("profile authorization UI wait ended after \(Self.setupWaitSeconds)s; native request may still be pending")
        }
        defer { timeoutTask.cancel() }

        do {
            try await HealthKitAuthorization.ensureAuthorized(for: .targetZoneProfile)
            guard authorizationAttempt == attempt else {
                return
            }
            authorizationAttempt = nil
            isRequestingAccess = false
            await loadProfile()
        } catch {
            guard authorizationAttempt == attempt else { return }
            authorizationAttempt = nil
            isRequestingAccess = false
            authorizationMessage = error.localizedDescription
            log("profile authorization UI error: \(error.localizedDescription)")
        }
    }

    private func missingDataMessage(for profile: HeartRateProfile) -> String {
        if profile.representativeRestingHR == nil {
            if case .error(let message) = profile.restingStatus {
                return "Could not read resting HR: \(message)"
            }
            return "No resting HR values are available from the last 30 days."
        }
        if case .error(let message) = profile.runningWorkoutStatus {
            return "Could not read running workouts: \(message)"
        }
        if case .error(let message) = profile.workoutHeartRateStatus {
            return "Could not read workout HR: \(message)"
        }
        if profile.workoutHeartRateQueryIssues > 0 {
            return "No sustained running HR peak was found; some workout HR data could not be read."
        }
        return "No sustained running HR peak is available from the last 90 days."
    }

    private func loadProfile() async {
        // Retrying data never initiates or waits for an authorization request.
        authorizationAttempt = nil
        isRequestingAccess = false
        authorizationMessage = nil
        let attempt = UUID()
        loadAttempt = attempt
        state = .loading
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(Self.setupWaitSeconds))
            } catch {
                return
            }
            guard loadAttempt == attempt, case .loading = state else { return }
            state = .failed("Heart-rate profile loading timed out. Please retry.")
            log("UI state -> error: profile request timed out after \(Self.setupWaitSeconds)s")
        }
        defer { timeoutTask.cancel() }

        do {
            let profile = try await HeartRateProfileService().load()
            guard loadAttempt == attempt else {
                return
            }
            guard !Task.isCancelled else {
                state = .failed("Heart-rate profile loading was interrupted. Please retry.")
                return
            }
            guard case .loading = state else {
                return
            }
            state = .loaded(profile)
            log("UI state -> loaded; resting available=\(profile.representativeRestingHR != nil), estimated max available=\(profile.estimatedMaxHR != nil)")
        } catch {
            guard loadAttempt == attempt else {
                return
            }
            guard case .loading = state else {
                return
            }
            let message = Task.isCancelled
                ? "Heart-rate profile loading was interrupted. Please retry."
                : error.localizedDescription
            state = .failed(message)
            log("UI state -> error: \(message)")
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[HeartRateProfile] \(message())")
        #endif
    }
}

private func zoneDescription(_ number: Int) -> String {
    switch number {
    case 1: "Recovery"
    case 2: "Endurance"
    case 3: "Tempo"
    case 4: "Threshold"
    case 5: "Anaerobic"
    default: ""
    }
}

private struct ZoneDetailView: View {
    let target: TargetHeartRateZone

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)

            Text("Zone \(target.number)")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(PaceTheme.primaryText)
            Text(zoneDescription(target.number))
                .font(.caption)
                .foregroundStyle(PaceTheme.secondaryText)

            Spacer(minLength: 4)

            Text("\(target.lowerBPM)–\(target.upperBPM)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(PaceTheme.primaryText)
            Text("BPM")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PaceTheme.accent)

            Spacer(minLength: 4)

            NavigationLink {
                ActiveZoneRunView(target: target)
            } label: {
                Label("Start Run", systemImage: "figure.run")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PaceTheme.accent)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaceTheme.background)
    }
}
