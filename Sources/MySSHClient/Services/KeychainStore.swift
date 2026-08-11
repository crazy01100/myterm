import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case operationFailed(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain 操作失敗（\(status)：\(message)）。"
            } else {
                "Keychain 操作失敗（\(status)）。"
            }
        case .invalidData: "Keychain 中的密碼資料無法讀取。"
        }
    }
}

enum KeychainDeletionResult: Equatable {
    case removed
    case notFound
    case manualCleanupRequired(OSStatus)
}

enum KeychainStore {
    static let service = "tw.local.MySSHClient.host-password"

    static func save(password: String, for hostID: UUID) throws {
        try save(passwordData: Data(password.utf8), for: hostID)
    }

    static func save(passwordData data: Data, for hostID: UUID) throws {
        try LocalSecretVaultStore.save(
            data,
            service: service,
            account: hostID.uuidString
        )
        NotificationCenter.default.post(name: .myTermPasswordDidChange, object: hostID)
    }

    static func passwordData(for hostID: UUID) throws -> Data? {
        if let data = try unifiedPasswordData(for: hostID) {
            return data
        }
        guard try LocalSecretVaultStore.shouldImportLegacy(
            service: service,
            account: hostID.uuidString
        ) else { return nil }

        guard var data = try legacyPasswordData(for: hostID) else { return nil }
        defer { data.resetBytes(in: data.indices) }
        try LocalSecretVaultStore.save(
            data,
            service: service,
            account: hostID.uuidString
        )
        guard try unifiedPasswordData(for: hostID) == data else {
            throw LocalSecretVaultError.verificationFailed
        }
        return data
    }

    /// Background work reads only the unified vault. This prevents automatic
    /// sync and diagnostics from unlocking every legacy per-host Keychain item.
    static func unifiedPasswordData(for hostID: UUID) throws -> Data? {
        try LocalSecretVaultStore.data(
            service: service,
            account: hostID.uuidString
        )
    }

    static func containsUnifiedPassword(for hostID: UUID) -> Bool {
        (try? LocalSecretVaultStore.contains(
            service: service,
            account: hostID.uuidString
        )) == true
    }

    private static func legacyPasswordData(for hostID: UUID) throws -> Data? {
        var query = baseQuery(hostID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        guard let data = item as? Data else { throw KeychainStoreError.invalidData }
        return data
    }

    static func containsPassword(for hostID: UUID) -> Bool {
        if (try? LocalSecretVaultStore.contains(
            service: service,
            account: hostID.uuidString
        )) == true {
            return true
        }
        if (try? LocalSecretVaultStore.shouldImportLegacy(
            service: service,
            account: hostID.uuidString
        )) == false {
            return false
        }
        var query = baseQuery(hostID)
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deletePassword(for hostID: UUID) throws -> KeychainDeletionResult {
        let removedFromVault = try LocalSecretVaultStore.delete(
            service: service,
            account: hostID.uuidString
        )
        let result: KeychainDeletionResult = removedFromVault ? .removed : .notFound
        if removedFromVault {
            NotificationCenter.default.post(name: .myTermPasswordDidChange, object: hostID)
        }
        return result
    }

    static func deletionResult(for status: OSStatus) throws -> KeychainDeletionResult {
        switch status {
        case errSecSuccess: .removed
        case errSecItemNotFound: .notFound
        case errSecInvalidOwnerEdit: .manualCleanupRequired(status)
        default: throw KeychainStoreError.operationFailed(status)
        }
    }

    private static func baseQuery(_ hostID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: hostID.uuidString
        ]
    }

}

extension Notification.Name {
    static let myTermPasswordDidChange = Notification.Name("MyTerm.PasswordDidChange")
}
