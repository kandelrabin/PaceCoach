import SwiftUI

struct CompanionTestView: View {
    @ObservedObject private var connectivity = CompanionConnectivity.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("iPhone Companion")
                    .font(.headline)
                Text(connectivity.status)
                    .font(.footnote)
                Text(connectivity.lastReceivedPing ?? "Waiting for a test message from iPhone.")
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
