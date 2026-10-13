import Combine
import Foundation
import WatchConnectivity

/// A small connectivity probe shared by the iPhone and Watch targets.
final class CompanionConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = CompanionConnectivity()

    @Published private(set) var status = "Starting Watch connection…"
    @Published private(set) var lastResult: String?
    @Published private(set) var lastReceivedPing: String?

    private override init() {
        super.init()
        guard WCSession.isSupported() else {
            status = "Watch Connectivity is unavailable on this device."
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

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
