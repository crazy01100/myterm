import Foundation
import Combine

enum SyncFeatureAvailability: Equatable {
    case notConfigured
    case ready
}

enum SyncSettingsError: LocalizedError, Equatable {
    case backendNotConfigured
    case signedOut

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: "雲端同步服務尚未完成設定，目前只能使用純本機模式。"
        case .signedOut: "請先登入要用來同步的 Google 帳戶。"
        }
    }
}

@MainActor
final class SyncSettingsStore: ObservableObject {
    static let unifiedSyncKey = "cloudSync.all.enabled.v2"
    static let metadataSyncKey = "cloudSync.metadata.enabled.v1"
    static let passwordSyncKey = "cloudSync.passwords.enabled.v1"
    private static let sessionRecoveryKey = "cloudSync.lastContext.enabled.v1"

    // Preserve the last known account's choice while startup authentication is unavailable.
    // This is intent only; it never enables data sync without a signed-in account.
    var sessionRecoveryEnabled: Bool {
        defaults.object(forKey: Self.sessionRecoveryKey) as? Bool
            ?? defaults.bool(forKey: Self.metadataSyncKey)
    }

    @Published private(set) var metadataSyncEnabled: Bool
    @Published private(set) var passwordSyncEnabled: Bool
    @Published private(set) var availability: SyncFeatureAvailability

    private let defaults: UserDefaults
    private var ownerUID: String?

    init(
        defaults: UserDefaults = .standard,
        availability: SyncFeatureAvailability = .notConfigured
    ) {
        self.defaults = defaults
        self.availability = availability
        metadataSyncEnabled = false
        passwordSyncEnabled = false
    }

    func setAvailability(_ availability: SyncFeatureAvailability) {
        setContext(availability: availability, ownerUID: ownerUID)
    }

    func setContext(availability: SyncFeatureAvailability, ownerUID: String?) {
        self.availability = availability
        self.ownerUID = ownerUID
        let enabled = availability == .ready
            && ownerUID.map { defaults.bool(forKey: scopedUnifiedKey(ownerUID: $0)) } == true
        metadataSyncEnabled = enabled
        passwordSyncEnabled = enabled
        if ownerUID != nil { defaults.set(enabled, forKey: Self.sessionRecoveryKey) }
    }

    func setMetadataSyncEnabled(_ enabled: Bool) throws {
        guard !enabled || availability == .ready else {
            throw SyncSettingsError.backendNotConfigured
        }
        guard !enabled || ownerUID != nil else { throw SyncSettingsError.signedOut }
        metadataSyncEnabled = enabled
        passwordSyncEnabled = enabled
        if let ownerUID {
            defaults.set(enabled, forKey: scopedUnifiedKey(ownerUID: ownerUID))
        }
        defaults.set(enabled, forKey: Self.metadataSyncKey)
        defaults.set(enabled, forKey: Self.passwordSyncKey)
        defaults.set(enabled, forKey: Self.sessionRecoveryKey)
    }

    func disableAll() {
        metadataSyncEnabled = false
        passwordSyncEnabled = false
        if let ownerUID {
            defaults.set(false, forKey: scopedUnifiedKey(ownerUID: ownerUID))
        }
        defaults.set(false, forKey: Self.metadataSyncKey)
        defaults.set(false, forKey: Self.passwordSyncKey)
        defaults.set(false, forKey: Self.sessionRecoveryKey)
    }

    private func scopedUnifiedKey(ownerUID: String) -> String {
        Self.unifiedSyncKey + "." + ownerUID
    }
}
