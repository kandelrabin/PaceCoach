/// A non-secret projection of saved connection and handoff progress, not a live
/// Strava health check. Independent of SwiftUI for deterministic checks.
struct StravaCompanionPresentation: Equatable {
    enum WatchSetup: String, Codable, CaseIterable {
        case pending, ready, failed, watchOwned
    }

    enum Screen { case initial, connecting, reconnecting, pending, healthy, recovery }
    enum Action { case connect, retryWatchSetup }

    let screen: Screen
    let canReconnect: Bool

    init(isConnected: Bool, isConnecting: Bool, watchSetup: WatchSetup?) {
        canReconnect = isConnected && !isConnecting
        if isConnecting {
            screen = isConnected ? .reconnecting : .connecting
        } else if !isConnected {
            screen = .initial
        } else {
            switch watchSetup {
            case .pending: screen = .pending
            case .ready, .watchOwned: screen = .healthy
            case .failed, nil: screen = .recovery
            }
        }
    }

    var title: String {
        switch screen {
        case .initial: "Connect to Strava"
        case .connecting: "Connecting to Strava…"
        case .reconnecting: "Reconnecting to Strava…"
        case .pending: "Setting up Apple Watch…"
        case .healthy: "Connected to Strava"
        case .recovery: "Finish Apple Watch setup"
        }
    }

    var explanation: String {
        switch screen {
        case .initial:
            "Connect once on your iPhone. Completed PaceCoach runs upload automatically from your Apple Watch."
        case .connecting, .reconnecting:
            "Complete the Strava sign-in to continue."
        case .pending:
            "Keep your iPhone and Apple Watch paired. Setup will finish when they can connect."
        case .healthy:
            "Completed PaceCoach runs upload automatically from your Apple Watch."
        case .recovery:
            "Your Strava connection is saved. Check that PaceCoach is installed on your paired Apple Watch, then try again."
        }
    }

    var primaryAction: Action? {
        switch screen {
        case .initial: .connect
        case .recovery: .retryWatchSetup
        default: nil
        }
    }

    var isBusy: Bool { screen == .connecting || screen == .reconnecting || screen == .pending }
}

#if canImport(UIKit)
import SwiftUI

struct StravaConnectionView: View {
    @StateObject private var connection = StravaConnection()
    @ObservedObject private var connectivity = CompanionConnectivity.shared

    private var presentation: StravaCompanionPresentation {
        StravaCompanionPresentation(isConnected: connection.isConnected,
                                    isConnecting: connection.isConnecting,
                                    watchSetup: connectivity.stravaSetupState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Strava")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label(presentation.title, systemImage: presentation.screen == .healthy
                      ? "checkmark.circle" : "applewatch")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(presentation.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if presentation.screen == .healthy {
                    Text("You don’t need to keep PaceCoach open on your iPhone.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            if presentation.isBusy {
                ProgressView()
                    .accessibilityLabel(presentation.title)
            }

            if let action = presentation.primaryAction {
                Button(action == .connect ? "Connect to Strava" : "Try Watch Setup Again") {
                    switch action {
                    case .connect: connection.connect()
                    case .retryWatchSetup: connection.provisionWatch()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if presentation.canReconnect {
                Button("Reconnect to Strava") {
                    connection.connect(forceApproval: true)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Use this if PaceCoach on your Watch asks you to reconnect.")
            }

            if let errorMessage = connection.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Color("AccentColor").opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }
}
#endif
