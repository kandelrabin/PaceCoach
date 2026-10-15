import SwiftUI

@main
struct PaceCoachCompanionApp: App {
    @StateObject private var connectivity = CompanionConnectivity.shared

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("PaceCoach")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .accessibilityAddTraits(.isHeader)

                    StravaConnectionView()

                    #if DEBUG
                    DisclosureGroup("Developer Tools") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(connectivity.status)
                            Text(connectivity.stravaProvisioningStatus)
                            Button("Send test message to Watch") {
                                connectivity.sendTestMessage()
                            }
                            if let result = connectivity.lastResult {
                                Text(result)
                            }
                        }
                        .font(.footnote)
                        .padding(.top, 12)
                    }
                    .foregroundStyle(.secondary)
                    #endif
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .background(Color.black)
            .tint(Color("AccentColor"))
            .preferredColorScheme(.dark)
        }
    }
}
