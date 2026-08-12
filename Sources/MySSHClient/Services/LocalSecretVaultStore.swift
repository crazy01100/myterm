import CryptoKit
import Foundation
import Security

enum LocalSecretVaultError: LocalizedError {
    case missingRootKey
    case invalidRootKey
    case unsupportedFormat
    case authenticationFailed
    case invalidIdentifier
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .missingRootKey:
            "本機機密保管庫存在，但其 Keychain 根金鑰遺失。為避免覆寫資料，MyTerm 已停止存取。"
        case .invalidRootKey:
            "本機機密保管庫的 Keychain 根金鑰格式不正確。"
        case .unsupportedFormat:
            "本機機密保管庫使用尚未支援的格式版本。"
        case .authenticationFailed:
            "本機機密保管庫驗證失敗，資料可能已損毀或根金鑰不相符。"
        case .invalidIdentifier:
            "機密資料缺少有效的服務或帳號識別。"
        case .verificationFailed:
            "機密資料寫入後驗證失敗；原有 Keychain 資料尚未移除。"
        }
    }
}

/// Stores all local secrets in one authenticated encrypted document. Only the
/// document's random root key remains in macOS Keychain, so a new MyTerm build
/// needs to unlock one Keychain item instead of every saved host password.
enum LocalSecretVaultStore {
    private static let schemaVersion = 1
    private static let rootKeyByteCount = 32
    private static let rootKeyAccount = "vault-v1"
    private static let productionRootKeyService = "tw.local.MySSHClient.local-secret-vault-root"
    private static let aad = Data("MyTerm.LocalSecretVault.v1".utf8)
    private static let lock = NSRecursiveLock()
    private static var cachedRootKey: Data?

    private struct Payload: Codable, Equatable {
        let schemaVersion: Int
        var entries: [String: Data]
        var suppressedLegacyEntries: Set<String>

        static let empty = Payload(
            schemaVersion: LocalSecretVaultStore.schemaVersion,
            entries: [:],
            suppressedLegacyEntries: []
        )

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case entries
            case suppressedLegacyEntries
        }

        init(
            schemaVersion: Int,
            entries: [String: Data],
            suppressedLegacyEntries: Set<String>
        ) {
            self.schemaVersion = schemaVersion
            self.entries = entries
            self.suppressedLegacyEntries = suppressedLegacyEntries
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            entries = try container.decode([String: Data].self, forKey: .entries)
            suppressedLegacyEntries = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .suppressedLegacyEntries
            ) ?? []
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let nonce: Data
        let ciphertext: Data
        let authenticationTag: Data
    }

    static func warmUp() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try rootKeyLocked()
    }

    static func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let payload = try loadPayloadLocked()
        return payload.entries[try entryKey(service: service, account: account)]
    }

    static func contains(service: String, account: String) throws -> Bool {
        try data(service: service, account: account) != nil
    }

    /// Returns false after an entry has either been imported into the unified
    /// vault or intentionally deleted. This prevents an old per-secret
    /// Keychain item from being resurrected without deleting that item and
    /// triggering another ownership/ACL prompt.
    static func shouldImportLegacy(service: String, account: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = try entryKey(service: service, account: account)
        let payload = try loadPayloadLocked()
        return payload.entries[key] == nil && !payload.suppressedLegacyEntries.contains(key)
    }

    static func save(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = try entryKey(service: service, account: account)
        var payload = try loadPayloadLocked()
        payload.entries[key] = data
        payload.suppressedLegacyEntries.remove(key)
        try savePayloadLocked(payload)

        let verified = try loadPayloadLocked().entries[key]
        guard verified == data else { throw LocalSecretVaultError.verificationFailed }
    }

    @discardableResult
    static func delete(service: String, account: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = try entryKey(service: service, account: account)
        var payload = try loadPayloadLocked()
        let removedValue = payload.entries.removeValue(forKey: key) != nil
        let insertedSuppression = payload.suppressedLegacyEntries.insert(key).inserted
        guard removedValue || insertedSuppression else { return false }
        try savePayloadLocked(payload)
        let verified = try loadPayloadLocked()
        guard verified.entries[key] == nil,
              verified.suppressedLegacyEntries.contains(key) else {
            throw LocalSecretVaultError.verificationFailed
        }
        return true
    }

    static func rootKeyUsesThisDeviceOnlyAccessibility() throws -> Bool {
        var query = rootKeyQuery
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        return true
    }

    private static func loadPayloadLocked() throws -> Payload {
        let rootKey = try rootKeyLocked()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let payload = Payload.empty
            try savePayloadLocked(payload, rootKey: rootKey)
            return payload
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        } catch {
            throw LocalSecretVaultError.authenticationFailed
        }
        guard envelope.schemaVersion == schemaVersion else {
            throw LocalSecretVaultError.unsupportedFormat
        }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext,
                tag: envelope.authenticationTag
            )
            let plaintext = try AES.GCM.open(
                box,
                using: encryptionKey(rootKey),
                authenticating: aad
            )
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            guard payload.schemaVersion == schemaVersion else {
                throw LocalSecretVaultError.unsupportedFormat
            }
            return payload
        } catch let error as LocalSecretVaultError {
            throw error
        } catch {
            throw LocalSecretVaultError.authenticationFailed
        }
    }

    private static func savePayloadLocked(_ payload: Payload, rootKey: Data? = nil) throws {
        guard payload.schemaVersion == schemaVersion else {
            throw LocalSecretVaultError.unsupportedFormat
        }
        let rootKey = try rootKey ?? rootKeyLocked()
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: encryptionKey(rootKey),
            authenticating: aad
        )
        let envelope = Envelope(
            schemaVersion: schemaVersion,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealed.ciphertext,
            authenticationTag: sealed.tag
        )
        try prepareDirectory()
        try JSONEncoder().encode(envelope).write(
            to: fileURL,
            options: [.atomic, .completeFileProtection]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func rootKeyLocked() throws -> Data {
        if let cachedRootKey { return cachedRootKey }

        var query = rootKeyQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let key = item as? Data, key.count == rootKeyByteCount else {
                throw LocalSecretVaultError.invalidRootKey
            }
            cachedRootKey = key
            return key
        case errSecItemNotFound:
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                throw LocalSecretVaultError.missingRootKey
            }
            let key = try randomData(count: rootKeyByteCount)
            var insert = rootKeyQuery
            insert[kSecValueData] = key
            insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                return try rootKeyLockedAfterConcurrentCreation()
            }
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.operationFailed(addStatus)
            }
            cachedRootKey = key
            try savePayloadLocked(.empty, rootKey: key)
            return key
        default:
            throw KeychainStoreError.operationFailed(status)
        }
    }

    private static func rootKeyLockedAfterConcurrentCreation() throws -> Data {
        var query = rootKeyQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let key = item as? Data,
              key.count == rootKeyByteCount else {
            throw status == errSecSuccess
                ? LocalSecretVaultError.invalidRootKey
                : KeychainStoreError.operationFailed(status)
        }
        cachedRootKey = key
        return key
    }

    private static var rootKeyQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: rootKeyService,
            kSecAttrAccount: rootKeyAccount
        ]
    }

    private static var rootKeyService: String {
#if MYTERM_SELF_TESTS
        if let service = ProcessInfo.processInfo.environment["MYTERM_SECRET_VAULT_KEYCHAIN_SERVICE"],
           !service.isEmpty {
            return service
        }
#endif
        if let configuredService = Bundle.main.object(
            forInfoDictionaryKey: "MyTermLocalSecretVaultKeychainService"
        ) as? String {
            let service = configuredService.trimmingCharacters(in: .whitespacesAndNewlines)
            if !service.isEmpty { return service }
        }
        return productionRootKeyService
    }

    private static var fileURL: URL {
#if MYTERM_SELF_TESTS
        if let path = ProcessInfo.processInfo.environment["MYTERM_SECRET_VAULT_FILE"],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
#endif
        return AppPaths.rootDirectory
            .appending(path: "Secret Vault", directoryHint: .isDirectory)
            .appending(path: "vault-v1.json")
    }

    private static func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func entryKey(service: String, account: String) throws -> String {
        guard !service.isEmpty, !account.isEmpty else {
            throw LocalSecretVaultError.invalidIdentifier
        }
        let digest = SHA256.hash(data: Data("\(service)\u{0}\(account)".utf8))
        return Data(digest).base64EncodedString()
    }

    private static func encryptionKey(_ rootKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rootKey),
            salt: Data("MyTerm.LocalSecretVault.HKDF.v1".utf8),
            info: aad,
            outputByteCount: rootKeyByteCount
        )
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        defer {
            _ = bytes.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        return Data(bytes)
    }

#if MYTERM_SELF_TESTS
    static var fileURLForTesting: URL { fileURL }

    static func clearCachedRootKeyForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cachedRootKey = nil
    }

    static func deleteRootKeyForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cachedRootKey = nil
        SecItemDelete(rootKeyQuery as CFDictionary)
    }

    static func corruptAuthenticationTagForTesting() throws {
        lock.lock()
        defer { lock.unlock() }
        let encoded = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: encoded)
        var tag = envelope.authenticationTag
        guard !tag.isEmpty else { throw LocalSecretVaultError.authenticationFailed }
        tag[0] ^= 0xff
        let corrupted = Envelope(
            schemaVersion: envelope.schemaVersion,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            authenticationTag: tag
        )
        try JSONEncoder().encode(corrupted).write(to: fileURL, options: .atomic)
    }

    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cachedRootKey = nil
        try? FileManager.default.removeItem(at: fileURL)
        SecItemDelete(rootKeyQuery as CFDictionary)
    }
#endif
}
