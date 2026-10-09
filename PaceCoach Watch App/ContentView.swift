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
            PaceSetupView()
        }
        .tint(PaceTheme.accent)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
