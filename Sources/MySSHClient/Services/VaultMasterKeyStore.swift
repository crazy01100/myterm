import Foundation
import Security

struct VaultMasterKey: Equatable, Sendable {
    static let byteCount = 32

    let rawRepresentation: Data
    let version: UInt32

    init(rawRepresentation: Data, version: UInt32) throws {
        guard rawRepresentation.count == Self.byteCount, version > 0 else {
            throw VaultCryptoError.invalidMasterKey
        }
        self.rawRepresentation = rawRepresentation
        self.version = version
    }

    static func generate(version: UInt32 = 1) throws -> Self {
        guard version > 0 else { throw VaultCryptoError.invalidMasterKey }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw VaultCryptoError.randomGenerationFailed(status)
        }
        defer {
            _ = bytes.withUnsafeMutableBytes { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        return try Self(rawRepresentation: Data(bytes), version: version)
    }
}

enum VaultMasterKeyStore {
    private static let service = "tw.local.MySSHClient.sync-master-key"

    static func save(_ key: VaultMasterKey, ownerUID: String) throws {
        guard !ownerUID.isEmpty else { throw VaultCryptoError.invalidOwner }
        let query = baseQuery(ownerUID: ownerUID, version: key.version)
        let attributes: [CFString: Any] = [
            kSecValueData: key.rawRepresentation,
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
            KeychainAccessPolicy.markNewItemIfReleaseSigned(&insert)
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        default:
            throw KeychainStoreError.operationFailed(lookupStatus)
        }
    }

    static func load(ownerUID: String, version: UInt32) throws -> VaultMasterKey? {
        var query = baseQuery(ownerUID: ownerUID, version: version)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        guard let data = item as? Data else { throw KeychainStoreError.invalidData }
        KeychainAccessPolicy.migrateAfterSuccessfulAccess(
            query: baseQuery(ownerUID: ownerUID, version: version),
            descriptor: "MyTerm 端對端加密主金鑰"
        )
        return try VaultMasterKey(rawRepresentation: data, version: version)
    }

    @discardableResult
    static func delete(ownerUID: String, version: UInt32) throws -> KeychainDeletionResult {
        let status = SecItemDelete(baseQuery(ownerUID: ownerUID, version: version) as CFDictionary)
        return try KeychainStore.deletionResult(for: status)
    }

    static func usesThisDeviceOnlyAccessibility(ownerUID: String, version: UInt32) throws -> Bool {
        var query = baseQuery(ownerUID: ownerUID, version: version)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        return true
    }

    private static func baseQuery(ownerUID: String, version: UInt32) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "\(ownerUID):\(version)"
        ]
    }
}
