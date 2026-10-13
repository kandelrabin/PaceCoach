import Foundation

/// Version 1 of the iPhone-to-Watch credential handoff. Never log or display this value.
struct StravaProvisioningPayload: Codable, Equatable {
    static let protocolVersion = 1

    let protocolVersion: Int
    let identifier: UUID
    let sequence: Int64
    let clientID: String
    let clientSecret: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
    let scope: String

    var isValid: Bool {
        protocolVersion == Self.protocolVersion && sequence > 0 &&
        !clientID.isEmpty && !clientSecret.isEmpty &&
        !clientID.hasPrefix("YOUR_") && !clientSecret.hasPrefix("YOUR_") &&
        !accessToken.isEmpty && !refreshToken.isEmpty && expiresAt > 0 &&
        scope.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .contains("activity:write")
    }
}
