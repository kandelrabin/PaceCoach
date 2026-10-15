//
//  PaceCoachApp.swift
//  PaceCoach Watch App
//
//  Created by Rabin Kandel on 09/10/2026.
//

import SwiftUI

@main
struct PaceCoach_Watch_AppApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = AutomaticStravaUploadFlow.shared
        _ = CompanionConnectivity.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase, initial: true) { _, phase in
                    AutomaticStravaUploadFlow.shared.setActive(phase == .active)
                }
        }
    }
}
