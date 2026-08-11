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
    private static let service = "tw.local.MySSHClient.host-password"

    static func save(password: String, for hostID: UUID) throws {
        try save(passwordData: Data(password.utf8), for: hostID)
    }

    static func save(passwordData data: Data, for hostID: UUID) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if let persistentReference = try persistentReference(for: hostID) {
            let updateStatus = SecItemUpdate(
                exactQuery(persistentReference) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.operationFailed(updateStatus)
            }
            NotificationCenter.default.post(name: .myTermPasswordDidChange, object: hostID)
            return
        }

        var insert = baseQuery(hostID)
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStoreError.operationFailed(addStatus) }
        NotificationCenter.default.post(name: .myTermPasswordDidChange, object: hostID)
    }

    static func passwordData(for hostID: UUID) throws -> Data? {
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
        var query = baseQuery(hostID)
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deletePassword(for hostID: UUID) throws -> KeychainDeletionResult {
        guard let persistentReference = try persistentReference(for: hostID) else { return .notFound }
        let deleteStatus = SecItemDelete(exactQuery(persistentReference) as CFDictionary)
        let result = try deletionResult(for: deleteStatus)
        if result == .removed {
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

    private static func persistentReference(for hostID: UUID) throws -> Data? {
        var lookup = baseQuery(hostID)
        lookup[kSecReturnPersistentRef] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status == errSecInvalidOwnerEdit {
            throw KeychainStoreError.operationFailed(status)
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.operationFailed(status)
        }
        guard let persistentReference = item as? Data else {
            throw KeychainStoreError.invalidData
        }
        return persistentReference
    }

    private static func exactQuery(_ persistentReference: Data) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: persistentReference
        ]
    }
}

extension Notification.Name {
    static let myTermPasswordDidChange = Notification.Name("MyTerm.PasswordDidChange")
}
