//
//  ContentView.swift
//  PaceCoach Watch App
//
//  Created by Rabin Kandel on 09/10/2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    NavigationLink {
                        PaceSetupView()
                    } label: {
                        modeLabel(
                            title: "Target Pace",
                            subtitle: "Stay within your target pace range",
                            symbol: "figure.run"
                        )
                    }

                    NavigationLink {
                        ZoneSetupView()
                    } label: {
                        modeLabel(
                            title: "Target Zone",
                            subtitle: "Train in a heart-rate zone",
                            symbol: "heart.fill"
                        )
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 14)
            }
            .background(PaceTheme.background)
        }
        .tint(PaceTheme.accent)
        .preferredColorScheme(.dark)
    }

    private func modeLabel(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PaceTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .bold))
                    .foregroundStyle(PaceTheme.primaryText)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaceTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
}
