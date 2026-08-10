import Foundation

/// A read-only Firestore view. `updateTimes` and `serverDate` are transport
/// metadata and never become part of the encrypted, authenticated payload.
struct FirestoreMetadataSnapshot: Sendable {
    let records: [EncryptedSyncRecord]
    let updateTimes: [UUID: Date]
    let serverDate: Date?
}

enum RecentCloudUpdatePolicy {
    static let confirmationWindow: TimeInterval = 5 * 60

    static func requiresConfirmation(
        updateTime: Date?,
        serverDate: Date?,
        window: TimeInterval = confirmationWindow
    ) -> Bool {
        guard let updateTime, let serverDate else { return true }
        return serverDate.timeIntervalSince(updateTime) < window
    }
}
