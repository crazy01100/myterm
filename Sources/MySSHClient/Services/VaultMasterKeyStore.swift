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
        try LocalSecretVaultStore.save(
            key.rawRepresentation,
            service: service,
            account: account(ownerUID: ownerUID, version: key.version)
        )
    }

    static func load(ownerUID: String, version: UInt32) throws -> VaultMasterKey? {
        let account = account(ownerUID: ownerUID, version: version)
        if let data = try LocalSecretVaultStore.data(service: service, account: account) {
            return try VaultMasterKey(rawRepresentation: data, version: version)
        }
        guard try LocalSecretVaultStore.shouldImportLegacy(
            service: service,
            account: account
        ) else { return nil }

        guard var data = try legacyMasterKeyData(ownerUID: ownerUID, version: version) else {
            return nil
        }
        defer { data.resetBytes(in: data.indices) }
        try LocalSecretVaultStore.save(data, service: service, account: account)
        return try VaultMasterKey(rawRepresentation: data, version: version)
    }

    private static func legacyMasterKeyData(ownerUID: String, version: UInt32) throws -> Data? {
        var query = baseQuery(ownerUID: ownerUID, version: version)
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
    static func delete(ownerUID: String, version: UInt32) throws -> KeychainDeletionResult {
        let removedFromVault = try LocalSecretVaultStore.delete(
            service: service,
            account: account(ownerUID: ownerUID, version: version)
        )
        return removedFromVault ? .removed : .notFound
    }

    static func usesThisDeviceOnlyAccessibility(ownerUID: String, version: UInt32) throws -> Bool {
        if try LocalSecretVaultStore.contains(
            service: service,
            account: account(ownerUID: ownerUID, version: version)
        ) {
            return try LocalSecretVaultStore.rootKeyUsesThisDeviceOnlyAccessibility()
        }
        guard try LocalSecretVaultStore.shouldImportLegacy(
            service: service,
            account: account(ownerUID: ownerUID, version: version)
        ) else { return false }
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
            kSecAttrAccount: account(ownerUID: ownerUID, version: version)
        ]
    }

    private static func account(ownerUID: String, version: UInt32) -> String {
        "\(ownerUID):\(version)"
    }
}
