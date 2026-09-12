import Foundation

enum GoogleSignInRetryError: LocalizedError {
    case expired, contextMismatch

    var errorDescription: String? {
        "這次 Google 驗證已無法繼續使用，請重新登入。"
    }
}

/// Process-local credential only. Deliberately not Codable or an Error payload.
/// Constructed by the auth client only after validating Google's ID token.
struct GoogleSignInRetryCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumAge: TimeInterval = 30 * 60
    static let expiryMargin: TimeInterval = 30
    let id = UUID()
    let requestURI: URL
    private let idToken: String
    private let clientID: String
    private let projectID: String
    private let expiresAt: Date
    private let deadline: ContinuousClock.Instant

    init(idToken: String, clientID: String, projectID: String, requestURI: URL, expiresAt: Date,
         now: Date = .now, instant: ContinuousClock.Instant = .now) {
        self.idToken = idToken
        self.clientID = clientID
        self.projectID = projectID
        self.requestURI = requestURI
        self.expiresAt = expiresAt
        let lifetime = expiresAt.timeIntervalSince(now) - Self.expiryMargin
        let usableLifetime = lifetime.isFinite ? max(0, min(Self.maximumAge, lifetime)) : 0
        deadline = instant.advanced(by: .seconds(usableLifetime))
    }

    func remainingLifetime(now: Date = .now, instant: ContinuousClock.Instant = .now) -> TimeInterval {
        let duration = instant.duration(to: deadline).components
        let monotonicRemaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let tokenRemaining = expiresAt.timeIntervalSince(now) - Self.expiryMargin
        guard tokenRemaining.isFinite else { return 0 }
        return max(0, min(monotonicRemaining, tokenRemaining))
    }

    func tokenForExchange(clientID: String, projectID: String, now: Date = .now,
                          instant: ContinuousClock.Instant = .now) throws -> String {
        guard self.clientID == clientID, self.projectID == projectID else {
            throw GoogleSignInRetryError.contextMismatch
        }
        guard !idToken.isEmpty, remainingLifetime(now: now, instant: instant) > 0 else {
            throw GoogleSignInRetryError.expired
        }
        return idToken
    }

    var description: String { "GoogleSignInRetryCredential(<redacted>)" }
    var debugDescription: String { description }
}
