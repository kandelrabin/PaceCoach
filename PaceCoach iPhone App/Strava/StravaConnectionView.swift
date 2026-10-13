import SwiftUI

struct StravaConnectionView: View {
    @StateObject private var connection = StravaConnection()
    @ObservedObject private var connectivity = CompanionConnectivity.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connection.isConnected {
                Label("Strava Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !connectivity.watchOwnsRefreshToken {
                    Button("Set Up Apple Watch") {
                        connection.provisionWatch()
                    }
                }
                Button("Reconnect Strava") {
                    connection.connect(forceApproval: true)
                }
                .disabled(connection.isConnecting)
                Text(connectivity.stravaProvisioningStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button(connection.isConnecting ? "Connecting…" : "Connect Strava") {
                    connection.connect()
                }
                .disabled(connection.isConnecting)
            }

            if let errorMessage = connection.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
