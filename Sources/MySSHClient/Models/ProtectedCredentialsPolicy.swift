import Foundation

/// A page-local lease. Times are monotonic seconds, never persisted or synced.
struct ProtectedCredentialsPolicy {
    static let idleDuration: TimeInterval = 60
    static let maximumDuration: TimeInterval = 300
    static let revealDuration: TimeInterval = 30
    static let clipboardDuration: TimeInterval = 30
    static let authenticationReturnDuration: TimeInterval = 2

    private(set) var attemptID: UUID?
    private(set) var authorizationID: UUID?
    private var authenticatedAt: TimeInterval?
    private var lastInteractionAt: TimeInterval?

    mutating func beginAuthentication() -> UUID {
        lock()
        let id = UUID()
        attemptID = id
        return id
    }

    mutating func completeAuthentication(_ id: UUID, succeeded: Bool, now: TimeInterval) -> Bool {
        guard attemptID == id else { return false }
        attemptID = nil
        guard succeeded, now.isFinite else { return false }
        authorizationID = UUID()
        authenticatedAt = now
        lastInteractionAt = now
        return true
    }

    func permitsAccess(at now: TimeInterval) -> Bool {
        guard authorizationID != nil, let authenticatedAt, let lastInteractionAt,
              now.isFinite, now >= authenticatedAt, now >= lastInteractionAt else { return false }
        return now - authenticatedAt < Self.maximumDuration && now - lastInteractionAt < Self.idleDuration
    }

    mutating func recordInteraction(at now: TimeInterval) {
        guard permitsAccess(at: now) else { lock(); return }
        lastInteractionAt = now
    }

    mutating func lock() {
        attemptID = nil
        authorizationID = nil
        authenticatedAt = nil
        lastInteractionAt = nil
    }
}

/// A focus handoff does not grant access. Only these system-installed agents
/// may temporarily own foreground focus during an outstanding LA request.
enum ProtectedCredentialsFocusPolicy {
    static func isSystemAuthenticationAgent(bundleID: String?, executablePath: String?) -> Bool {
        guard let bundleID, let executablePath else { return false }
        let expected: String
        switch bundleID {
        case "com.apple.LocalAuthentication.UIAgent":
            expected = "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"
        case "com.apple.SecurityAgent":
            expected = "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent"
        default: return false
        }
        return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
    }
}

/// Only connection identity participates; a name/group/recency change is not a
/// different credential, whereas changing account or authentication method is.
struct ProtectedCredentialIdentity: Equatable {
    let hostID: UUID
    let hostname: String
    let port: Int
    let username: String
    let method: AuthenticationMethod

    init(_ host: HostProfile) {
        hostID = host.id
        hostname = host.hostname
        port = host.port
        username = host.username
        method = host.authenticationMethod
    }

    var canReadPassword: Bool { method == .password && !username.isEmpty }
}

enum ProtectedCredentialsList {
    static func filtered(_ hosts: [HostProfile], query: String) -> [HostProfile] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return hosts.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
                || String($0.port).contains(query)
        }.sorted {
            let name = $0.displayName.localizedStandardCompare($1.displayName)
            if name != .orderedSame { return name == .orderedAscending }
            let address = $0.addressDescription.localizedStandardCompare($1.addressDescription)
            return address == .orderedSame ? $0.id.uuidString < $1.id.uuidString : address == .orderedAscending
        }
    }
}
