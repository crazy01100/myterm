import Foundation

enum TerminalFontZoomAction {
    case increase, decrease, reset
}

enum TerminalFontSizePolicy {
    static let defaultSize = 14
    static let minimumSize = 10
    static let maximumSize = 32

    static func size(after action: TerminalFontZoomAction, current: Int) -> Int {
        let bounded = min(maximumSize, max(minimumSize, current))
        switch action {
        case .increase: return min(maximumSize, bounded + 1)
        case .decrease: return max(minimumSize, bounded - 1)
        case .reset: return defaultSize
        }
    }
}

enum TerminalConnectionIndicator: Equatable {
    case connecting
    case connected
    case disconnected
    case failed

    init(state: SessionState) {
        switch state {
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .failed:
            self = .failed
        }
    }
}

struct TerminalSessionPresentationNameRegistry {
    private struct Entry {
        let baseName: String
        var ordinal: Int
    }

    private var entries: [UUID: Entry] = [:]

    mutating func register(sessionID: UUID, baseName: String) {
        guard entries[sessionID] == nil else { return }
        let matchingIDs = entries.compactMap { id, entry in
            entry.baseName == baseName ? id : nil
        }

        let ordinal: Int
        if matchingIDs.isEmpty {
            ordinal = 1
        } else if matchingIDs.count == 1, let existingID = matchingIDs.first {
            // A lone session is displayed without a suffix, so normalizing its
            // hidden ordinal does not change anything the user has already seen.
            entries[existingID]?.ordinal = 1
            ordinal = 2
        } else {
            ordinal = matchingIDs
                .compactMap { entries[$0]?.ordinal }
                .max()
                .map { $0 + 1 } ?? 1
        }

        entries[sessionID] = Entry(baseName: baseName, ordinal: ordinal)
    }

    mutating func remove(sessionID: UUID) {
        entries.removeValue(forKey: sessionID)
    }

    func presentationName(sessionID: UUID, baseName: String) -> String {
        let matchingCount = entries.values.reduce(into: 0) { count, entry in
            if entry.baseName == baseName { count += 1 }
        }
        guard matchingCount > 1,
              let entry = entries[sessionID],
              entry.baseName == baseName else {
            return baseName
        }
        return "\(baseName) (\(entry.ordinal))"
    }
}

struct TerminalOutputActivityIndex: Equatable {
    private(set) var unreadSessionIDs: Set<UUID> = []

    @discardableResult
    mutating func recordOutput(sessionID: UUID, isWorkspaceVisible: Bool) -> Bool {
        guard !isWorkspaceVisible else { return false }
        return unreadSessionIDs.insert(sessionID).inserted
    }

    @discardableResult
    mutating func markViewed(sessionIDs: [UUID]) -> Bool {
        let previousCount = unreadSessionIDs.count
        unreadSessionIDs.subtract(sessionIDs)
        return unreadSessionIDs.count != previousCount
    }

    @discardableResult
    mutating func remove(sessionID: UUID) -> Bool {
        unreadSessionIDs.remove(sessionID) != nil
    }

    func containsUnread(in sessionIDs: [UUID]) -> Bool {
        sessionIDs.contains { unreadSessionIDs.contains($0) }
    }
}
