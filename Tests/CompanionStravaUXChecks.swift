import Foundation

// Compile with the iPhone StravaConnectionView.swift. The presentation runs on
// macOS without UIKit. Source integration guards cover the real OAuth save and
// handoff boundary without opening a browser, touching Keychain, or credentials.
// Optional arguments: the built Release and Debug iPhone executable paths.
@main
struct CompanionStravaUXChecks {
    private typealias Presentation = StravaCompanionPresentation
    private static var checks = 0

    static func main() throws {
        try presentationStates()
        actionAvailability()
        try authorizationAndProvisioningBoundaries()
        try diagnosticsAreDebugOnly()
        if CommandLine.arguments.count == 3 {
            try builtDiagnostics(release: CommandLine.arguments[1], debug: CommandLine.arguments[2])
        }
        print("Companion Strava UX checks passed (\(checks) assertions)")
    }

    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    private static func state(_ setup: Presentation.WatchSetup?, connected: Bool = true,
                              connecting: Bool = false) -> Presentation {
        Presentation(isConnected: connected, isConnecting: connecting, watchSetup: setup)
    }

    private static func presentationStates() throws {
        let initial = state(nil, connected: false)
        check(initial.screen == .initial && initial.primaryAction == .connect, "fresh install offers connection")
        check(initial.title == "Connect to Strava", "initial action is clear")
        check(!initial.canReconnect && !initial.isBusy, "fresh install has no recovery action")
        let pending = state(.pending)
        check(pending.screen == .pending && pending.isBusy, "saved credentials with pending handoff show setup progress")
        check(pending.primaryAction == nil, "pending delivery cannot enqueue another setup")
        check(pending.canReconnect, "pending delivery retains an explicit reauthorization escape path")
        let ready = state(.ready)
        let owned = state(.watchOwned)
        check(ready.screen == .healthy, "acknowledged readiness is healthy")
        check(owned == ready, "Watch refresh ownership has identical healthy production presentation")
        check(ready.title == "Connected to Strava", "healthy title communicates connection")
        check(ready.primaryAction == nil && ready.canReconnect, "healthy state has only secondary reconnect")
        check(!ready.isBusy, "healthy state stops progress")
        for setup: Presentation.WatchSetup? in [nil, .failed] {
            let recovery = state(setup)
            check(recovery.screen == .recovery, "missing or failed handoff needs setup recovery")
            check(recovery.primaryAction == .retryWatchSetup, "recovery offers one explicit retry")
        }
        check(state(nil, connected: false, connecting: true).screen == .connecting, "initial authorization shows progress")
        for setup: Presentation.WatchSetup? in [nil, .pending, .ready, .failed, .watchOwned] {
            let reconnecting = state(setup, connecting: true)
            check(reconnecting.screen == .reconnecting, "reconnect has distinct progress")
            check(reconnecting.primaryAction == nil && !reconnecting.canReconnect, "OAuth disables every conflicting action")
        }
        let legacyStates: [(String, Presentation.WatchSetup)] = [
            ("pending", .pending), ("ready", .ready), ("failed", .failed), ("watchOwned", .watchOwned)
        ]
        for (rawValue, expected) in legacyStates {
            let decoded = try JSONDecoder().decode(Presentation.WatchSetup.self,
                                                   from: JSONEncoder().encode(rawValue))
            check(decoded == expected, "existing persisted handoff states remain compatible")
        }
    }

    private static func actionAvailability() {
        for connected in [false, true] {
            for connecting in [false, true] {
                for setup: Presentation.WatchSetup? in [nil, .pending, .ready, .failed, .watchOwned] {
                    let presentation = state(setup, connected: connected, connecting: connecting)
                    check(presentation.primaryAction == .retryWatchSetup
                          ? connected && !connecting && (setup == nil || setup == .failed)
                          : true, "setup retry requires saved credentials and actual intervention")
                    if !connecting && connected && (setup == .ready || setup == .watchOwned || setup == .pending) {
                        check(presentation.primaryAction == nil, "pending/healthy never offer setup again")
                    }
                    let copy = (presentation.title + " " + presentation.explanation).lowercased()
                    for forbidden in ["token", "keychain", "http", "credential", "reachable", "rebuild", "test message"] {
                        check(!copy.contains(forbidden), "production state copy omits implementation diagnostics")
                    }
                }
            }
        }
    }

    private static func authorizationAndProvisioningBoundaries() throws {
        let source = try String(contentsOfFile: "PaceCoach iPhone App/Strava/StravaConnection.swift", encoding: .utf8)
        let initBody = source.components(separatedBy: "    init() {")[1]
            .components(separatedBy: "    func connect(")[0]
        check(!initBody.contains("queueWatchProvisioning()"), "launch never resends saved phone credentials")
        let retry = source.components(separatedBy: "    func provisionWatch() {")[1]
            .components(separatedBy: "    private func queueWatchProvisioning()")[0]
        check(retry.contains("guard presentation.primaryAction == .retryWatchSetup else { return }"),
              "real retry endpoint uses the tested action gate")
        let finish = source.components(separatedBy: "    private func finish(")[1]
            .components(separatedBy: "    private func exchange(")[0]
        let saved = finish.range(of: "try tokenStore.save(tokens)")!
        let invalidate = finish.range(of: "CompanionConnectivity.shared.invalidateStravaProvisioningStatus()")!
        let provision = finish.range(of: "queueWatchProvisioning()")!
        check(saved.lowerBound < invalidate.lowerBound && invalidate.lowerBound < provision.lowerBound,
              "OAuth success securely saves before invalidating and automatically provisioning")
        check(finish.components(separatedBy: "queueWatchProvisioning()").count == 2,
              "initial OAuth and reconnect share exactly one automatic handoff")
        let beforeSave = String(finish[..<saved.lowerBound])
        let catches = String(finish[provision.upperBound...])
        for unchanged in [beforeSave, catches] {
            check(!unchanged.contains("invalidateStravaProvisioningStatus()"), "cancel/validation/storage/network failure preserves old handoff")
            check(!unchanged.contains("isConnected = false"), "failed reconnect preserves saved connection state")
            check(!unchanged.contains("tokenStore.save("), "unsuccessful reconnect cannot replace credentials")
        }
        check(finish.contains("isConnecting = false"), "all OAuth exits release busy state")
        check(finish.contains("Strava connection cancelled."), "cancellation has concise user copy")
        check(finish.contains("guard tokens.grantsActivityWrite"), "response scope validation is preserved")
        check(source.contains("parts.fragment == nil") && source.contains("uniqueValue(\"state\") == expectedState"),
              "callback and CSRF validation remain intact")
        let connectivity = try String(contentsOfFile: "Shared/CompanionConnectivity.swift", encoding: .utf8)
        let queue = connectivity.components(separatedBy: "    func queueStravaProvisioning(")[1]
            .components(separatedBy: "    private func updateProgress(")[0]
        check(queue.contains("session.transferUserInfo("), "handoff keeps background/deferred transfer")
        check(!queue.contains("isReachable"), "handoff does not require foreground reachability")
        check(connectivity.contains("stravaSetupState = saved.state"), "relaunch restores typed handoff state")
        check(connectivity.contains("stravaSetupState = value.state"), "acknowledgements publish typed presentation state")
        check(connectivity.contains("stravaSetupState = nil"), "successful reauthorization resets old presentation state")
    }

    private static func diagnosticsAreDebugOnly() throws {
        let app = try String(contentsOfFile: "PaceCoach iPhone App/PaceCoachCompanionApp.swift", encoding: .utf8)
        let connectivity = try String(contentsOfFile: "Shared/CompanionConnectivity.swift", encoding: .utf8)
        check(!connectivity.contains("#if DEBUG || os(iOS)"), "iPhone Release cannot opt into DEBUG tooling")
        let appTools = app.components(separatedBy: "#if DEBUG")[1].components(separatedBy: "#endif")[0]
        for marker in ["Send test message to Watch", "connectivity.status", "connectivity.lastResult", "Developer Tools"] {
            check(appTools.contains(marker), "diagnostic UI is DEBUG-only")
            check(!app.replacingOccurrences(of: appTools, with: "").contains(marker), "diagnostic UI has no production duplicate")
        }
        let debugSections = connectivity.components(separatedBy: "#if DEBUG").dropFirst()
            .map { $0.components(separatedBy: "#endif")[0] }.joined()
        for marker in ["func sendTestMessage()", "var lastResult", "var lastReceivedPing", "pacecoach.test.ping"] {
            check(debugSections.contains(marker), "ping API/storage is guarded by DEBUG")
            check(debugSections.components(separatedBy: marker).count == connectivity.components(separatedBy: marker).count,
                  "ping API/storage has no production duplicate")
        }
        let view = try String(contentsOfFile: "PaceCoach iPhone App/Strava/StravaConnectionView.swift", encoding: .utf8)
        check(!view.contains("stravaProvisioningStatus"), "production card never renders diagnostic handoff labels")
        check(!view.contains("Manage access") && !view.contains("Disconnect"), "no new product controls")
    }

    private static func builtDiagnostics(release: String, debug: String) throws {
        let releaseData = try Data(contentsOf: URL(fileURLWithPath: release))
        let debugData = try Data(contentsOf: URL(fileURLWithPath: debug))
        for marker in ["Send test message to Watch", "Developer Tools", "pacecoach.test.ping", "sendTestMessage", "lastReceivedPing"] {
            let needle = Data(marker.utf8)
            check(releaseData.range(of: needle) == nil, "Release executable excludes ping/test controls")
            check(debugData.range(of: needle) != nil, "Debug executable retains diagnostics, validating the binary check")
        }
    }
}
