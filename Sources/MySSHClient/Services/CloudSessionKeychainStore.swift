import Foundation
import Security

enum CloudSessionKeychainStore {
    private static let service = "tw.local.MySSHClient.firebase-session"

    static func saveRefreshToken(_ token: String, projectID: String) throws {
        try LocalSecretVaultStore.save(
            Data(token.utf8),
            service: service,
            account: projectID
        )
    }

    static func refreshToken(projectID: String) throws -> String? {
        if let data = try LocalSecretVaultStore.data(service: service, account: projectID) {
            guard let token = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.invalidData
            }
            return token
        }
        guard try LocalSecretVaultStore.shouldImportLegacy(
            service: service,
            account: projectID
        ) else { return nil }

        guard var data = try legacyRefreshTokenData(projectID: projectID) else { return nil }
        defer { data.resetBytes(in: data.indices) }
        try LocalSecretVaultStore.save(data, service: service, account: projectID)
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return token
    }

    private static func legacyRefreshTokenData(projectID: String) throws -> Data? {
        var query = baseQuery(projectID: projectID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        guard let data = item as? Data else { throw KeychainStoreError.invalidData }
        return data
    }

    @discardableResult
    static func deleteRefreshToken(projectID: String) throws -> KeychainDeletionResult {
        let removedFromVault = try LocalSecretVaultStore.delete(
            service: service,
            account: projectID
        )
        return removedFromVault ? .removed : .notFound
    }

    private static func baseQuery(projectID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: projectID
        ]
    }
}
