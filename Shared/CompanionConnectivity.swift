import Combine
import Foundation
import WatchConnectivity

/// The one WatchConnectivity delegate for the companion proof and Strava handoff.
final class CompanionConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = CompanionConnectivity()

    @Published private(set) var status = "Starting Watch connection…"
    @Published private(set) var lastResult: String?
    @Published private(set) var lastReceivedPing: String?
    @Published private(set) var stravaProvisioningStatus = "Strava is not set up on this Watch."

    private static let provisioningKind = "pacecoach.strava.provision.v1"
    private static let acknowledgementKind = "pacecoach.strava.provision.ack.v1"

    #if os(iOS)
    private static let progressKey = "stravaProvisioningProgress"
    private var progress: ProvisioningProgress?
    #endif

    private override init() {
        super.init()
        #if os(iOS)
        if let data = UserDefaults.standard.data(forKey: Self.progressKey),
           let saved = try? JSONDecoder().decode(ProvisioningProgress.self, from: data) {
            progress = saved
            stravaProvisioningStatus = saved.label
        } else {
            stravaProvisioningStatus = "Apple Watch has not been set up for Strava."
        }
        #else
        do {
            stravaProvisioningStatus = try WatchStravaCredentialStore().load() == nil
                ? "Strava is not set up on this Watch."
                : "Strava Ready on Watch"
        } catch {
            stravaProvisioningStatus = "Could not read Watch Strava setup."
        }
        #endif
        guard WCSession.isSupported() else {
            status = "Watch Connectivity is unavailable on this device."
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if os(iOS)
    func queueStravaProvisioning(_ payload: StravaProvisioningPayload) throws {
        let session = WCSession.default
        guard payload.isValid, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else {
            throw ProvisioningTransferError.unavailable
        }
        let data = try JSONEncoder().encode(payload)
        session.transferUserInfo([
            "kind": Self.provisioningKind,
            "identifier": payload.identifier.uuidString,
            "sequence": payload.sequence,
            "payload": data
        ])
        updateProgress(ProvisioningProgress(identifier: payload.identifier,
                                            sequence: payload.sequence, state: .pending))
    }

    private func updateProgress(_ value: ProvisioningProgress) {
        progress = value
        stravaProvisioningStatus = value.label
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.progressKey)
        }
    }

    func invalidateStravaProvisioningStatus() {
        progress = nil
        stravaProvisioningStatus = "Apple Watch needs Strava setup."
        UserDefaults.standard.removeObject(forKey: Self.progressKey)
    }
    #endif

    func sendTestMessage() {
        let session = WCSession.default
        guard session.activationState == .activated else {
            lastResult = "Connection is still starting. Try again."
            return
        }
        guard session.isReachable else {
            lastResult = "Open PaceCoach on the Watch, then try again."
            return
        }

        let nonce = UUID().uuidString
        lastResult = "Waiting for Watch acknowledgment…"
        session.sendMessage(["kind": "pacecoach.test.ping", "nonce": nonce]) { [weak self] reply in
            DispatchQueue.main.async {
                if reply["kind"] as? String == "pacecoach.test.pong",
                   reply["nonce"] as? String == nonce {
                    self?.lastResult = "Watch acknowledged the test message."
                } else {
                    self?.lastResult = "Watch returned an unexpected reply."
                }
            }
        } errorHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.lastResult = "Message failed. Keep both apps open and try again."
            }
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.status = error == nil && activationState == .activated
                ? (session.isReachable ? "Companion reachable" : "Companion not currently reachable")
                : "Could not activate Watch Connectivity."
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.status = session.isReachable
                ? "Companion reachable"
                : "Companion not currently reachable"
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["kind"] as? String == "pacecoach.test.ping",
              let nonce = message["nonce"] as? String else {
            replyHandler(["kind": "pacecoach.test.unsupported"])
            return
        }
        DispatchQueue.main.async {
            self.lastReceivedPing = "Test message received from iPhone."
        }
        replyHandler(["kind": "pacecoach.test.pong", "nonce": nonce])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        #if os(iOS)
        guard userInfo["kind"] as? String == Self.acknowledgementKind,
              let identifierString = userInfo["identifier"] as? String,
              let identifier = UUID(uuidString: identifierString),
              let sequence = userInfo["sequence"] as? Int64,
              let result = userInfo["result"] as? String else { return }
        DispatchQueue.main.async {
            guard let current = self.progress, current.state == .pending,
                  current.identifier == identifier, current.sequence == sequence else { return }
            self.updateProgress(ProvisioningProgress(identifier: identifier,
                                                     sequence: sequence,
                                                     state: result == "ready" ? .ready : .failed))
        }
        #else
        guard userInfo["kind"] as? String == Self.provisioningKind,
              let identifierString = userInfo["identifier"] as? String,
              let identifier = UUID(uuidString: identifierString),
              let sequence = userInfo["sequence"] as? Int64, sequence > 0 else { return }
        var result = "failed"
        do {
            guard let data = userInfo["payload"] as? Data, data.count <= 65_536 else {
                throw WatchStravaStoreError.invalidPayload
            }
            let payload = try JSONDecoder().decode(StravaProvisioningPayload.self, from: data)
            guard payload.identifier == identifier, payload.sequence == sequence else {
                throw WatchStravaStoreError.invalidPayload
            }
            try WatchStravaCredentialStore().accept(payload)
            result = "ready"
            DispatchQueue.main.async {
                self.stravaProvisioningStatus = "Strava Ready on Watch"
            }
        } catch WatchStravaStoreError.stalePayload {
            // Keep the newer persisted setup. The iPhone can retry with a new version.
        } catch {
            DispatchQueue.main.async {
                self.stravaProvisioningStatus = "Strava setup failed on Watch."
            }
        }
        session.transferUserInfo([
            "kind": Self.acknowledgementKind,
            "identifier": identifier.uuidString,
            "sequence": sequence,
            "result": result
        ])
        #endif
    }

    #if os(iOS)
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                 error: Error?) {
        guard error != nil,
              userInfoTransfer.userInfo["kind"] as? String == Self.provisioningKind,
              let identifierString = userInfoTransfer.userInfo["identifier"] as? String,
              let identifier = UUID(uuidString: identifierString),
              let sequence = userInfoTransfer.userInfo["sequence"] as? Int64 else { return }
        DispatchQueue.main.async {
            guard let current = self.progress, current.state == .pending,
                  current.identifier == identifier, current.sequence == sequence else { return }
            self.updateProgress(ProvisioningProgress(identifier: identifier,
                                                     sequence: sequence, state: .failed))
        }
    }
    #endif

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async {
            self.status = "Watch connection inactive."
        }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}

#if os(iOS)
private enum ProvisioningTransferError: Error {
    case unavailable
}

private struct ProvisioningProgress: Codable {
    enum State: String, Codable {
        case pending
        case ready
        case failed
    }

    let identifier: UUID
    let sequence: Int64
    let state: State

    var label: String {
        switch state {
        case .pending: "Watch setup pending. Keep the devices paired; delivery may take time."
        case .ready: "Strava Ready on Watch"
        case .failed: "Watch setup failed. Tap Set Up Apple Watch to retry."
        }
    }
}
#endif
