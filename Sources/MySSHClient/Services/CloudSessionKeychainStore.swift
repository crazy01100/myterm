import Foundation
import Security

enum CloudSessionKeychainStore {
    private static let service = "tw.local.MySSHClient.firebase-session"

    static func saveRefreshToken(_ token: String, projectID: String) throws {
        let query = baseQuery(projectID: projectID)
        let attributes: [CFString: Any] = [
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, nil)
        switch lookupStatus {
        case errSecSuccess:
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        case errSecItemNotFound:
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        default:
            throw KeychainStoreError.operationFailed(lookupStatus)
        }
    }

    static func refreshToken(projectID: String) throws -> String? {
        var query = baseQuery(projectID: projectID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return token
    }

    @discardableResult
    static func deleteRefreshToken(projectID: String) throws -> KeychainDeletionResult {
        let status = SecItemDelete(baseQuery(projectID: projectID) as CFDictionary)
        return try KeychainStore.deletionResult(for: status)
    }

    private static func baseQuery(projectID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: projectID
        ]
    }
}
