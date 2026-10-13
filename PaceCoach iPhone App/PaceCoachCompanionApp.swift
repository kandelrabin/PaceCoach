import SwiftUI

@main
struct PaceCoachCompanionApp: App {
    @StateObject private var connectivity = CompanionConnectivity.shared

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Image(systemName: "applewatch")
                    .font(.largeTitle)
                Text("PaceCoach companion installed")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(connectivity.status)
                    .foregroundStyle(.secondary)
                Button("Send test message to Watch") {
                    connectivity.sendTestMessage()
                }
                if let result = connectivity.lastResult {
                    Text(result)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
    }
}
