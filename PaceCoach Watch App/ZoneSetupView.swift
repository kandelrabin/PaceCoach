import SwiftUI

struct ZoneSetupView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(PaceTheme.accent)

            Text("Target Zone")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(PaceTheme.primaryText)

            Text("Heart-rate zone setup is coming soon.")
                .font(.caption)
                .foregroundStyle(PaceTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaceTheme.background)
    }
}
