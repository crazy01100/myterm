import CryptoKit
import Foundation

struct LocalVaultEnvelopeDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let ownerUID: String
    let passphraseEnvelope: VaultKeyEnvelope
    let recoveryEnvelope: VaultKeyEnvelope
    let createdAt: Date
    var recoveryConfirmedAt: Date?

    init(
        schemaVersion: UInt32 = currentSchemaVersion,
        ownerUID: String,
        passphraseEnvelope: VaultKeyEnvelope,
        recoveryEnvelope: VaultKeyEnvelope,
        createdAt: Date,
        recoveryConfirmedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.ownerUID = ownerUID
        self.passphraseEnvelope = passphraseEnvelope
        self.recoveryEnvelope = recoveryEnvelope
        self.createdAt = createdAt
        self.recoveryConfirmedAt = recoveryConfirmedAt
    }
}

struct LocalVaultSummary: Equatable, Sendable {
    let createdAt: Date
    let keyVersion: UInt32
    let recoveryConfirmed: Bool
}

enum VaultSetupError: LocalizedError, Equatable {
    case invalidOwner
    case alreadyExists
    case notFound
    case unsupportedDocument
    case ownerMismatch
    case missingLocalMasterKey

    var errorDescription: String? {
        switch self {
        case .invalidOwner: "缺少有效的 Google 帳號識別。"
        case .alreadyExists: "這個帳號已經在本機建立加密保管庫。"
        case .notFound: "找不到這個帳號的本機加密保管庫。"
        case .unsupportedDocument: "本機加密保管庫使用尚未支援的格式。"
        case .ownerMismatch: "本機加密保管庫不屬於目前登入的帳號。"
        case .missingLocalMasterKey: "這台 Mac 的 Keychain 中沒有保管庫主金鑰。"
        }
    }
}

struct VaultEnvelopeStore: Sendable {
    let directory: URL

    init(directory: URL = AppPaths.syncDirectory) {
        self.directory = directory
    }

    func load(ownerUID: String) throws -> LocalVaultEnvelopeDocument? {
        let url = try documentURL(ownerUID: ownerUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let document = try JSONDecoder.vaultDecoder.decode(
            LocalVaultEnvelopeDocument.self,
            from: Data(contentsOf: url)
        )
        guard document.schemaVersion == LocalVaultEnvelopeDocument.currentSchemaVersion else {
            throw VaultSetupError.unsupportedDocument
        }
        guard document.ownerUID == ownerUID else { throw VaultSetupError.ownerMismatch }
        return document
    }

    func save(_ document: LocalVaultEnvelopeDocument) throws {
        guard !document.ownerUID.isEmpty else { throw VaultSetupError.invalidOwner }
        try prepareDirectory()
        let url = try documentURL(ownerUID: document.ownerUID)
        let data = try JSONEncoder.vaultEncoder.encode(document)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func fileURL(ownerUID: String) throws -> URL {
        try documentURL(ownerUID: ownerUID)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func documentURL(ownerUID: String) throws -> URL {
        guard !ownerUID.isEmpty else { throw VaultSetupError.invalidOwner }
        let digest = SHA256.hash(data: Data(ownerUID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "vault-\(digest).json")
    }
}

struct LocalVaultCreation: Sendable {
    let document: LocalVaultEnvelopeDocument
    let recoveryKey: String
}

enum VaultSetupService {
    static func create(
        ownerUID: String,
        passphrase: String,
        envelopeStore: VaultEnvelopeStore = VaultEnvelopeStore()
    ) throws -> LocalVaultCreation {
        guard !ownerUID.isEmpty else { throw VaultSetupError.invalidOwner }
        guard try envelopeStore.load(ownerUID: ownerUID) == nil else {
            throw VaultSetupError.alreadyExists
        }

        let masterKey = try VaultMasterKey.generate(version: VaultCryptoFormat.masterKeyVersion)
        let recoveryKey = try VaultRecoveryKey.generate()
        let createdAt = persistedTimestamp()
        let passphraseEnvelope = try VaultKeyEnvelopeCrypto.sealWithPassphrase(
            masterKey: masterKey,
            ownerUID: ownerUID,
            passphrase: passphrase,
            createdAt: createdAt
        )
        let recoveryEnvelope = try VaultKeyEnvelopeCrypto.sealWithRecoveryKey(
            masterKey: masterKey,
            ownerUID: ownerUID,
            recoveryKey: recoveryKey,
            createdAt: createdAt
        )
        let document = LocalVaultEnvelopeDocument(
            ownerUID: ownerUID,
            passphraseEnvelope: passphraseEnvelope,
            recoveryEnvelope: recoveryEnvelope,
            createdAt: createdAt
        )

        try VaultMasterKeyStore.save(masterKey, ownerUID: ownerUID)
        do {
            try envelopeStore.save(document)
        } catch {
            _ = try? VaultMasterKeyStore.delete(ownerUID: ownerUID, version: masterKey.version)
            throw error
        }
        return LocalVaultCreation(document: document, recoveryKey: recoveryKey.exportString)
    }

    static func confirmRecoveryKey(
        ownerUID: String,
        envelopeStore: VaultEnvelopeStore = VaultEnvelopeStore()
    ) throws -> LocalVaultEnvelopeDocument {
        guard var document = try envelopeStore.load(ownerUID: ownerUID) else {
            throw VaultSetupError.notFound
        }
        document.recoveryConfirmedAt = persistedTimestamp()
        try envelopeStore.save(document)
        return document
    }

    static func replaceUnconfirmedRecoveryKey(
        ownerUID: String,
        envelopeStore: VaultEnvelopeStore = VaultEnvelopeStore()
    ) throws -> LocalVaultCreation {
        guard var document = try envelopeStore.load(ownerUID: ownerUID) else {
            throw VaultSetupError.notFound
        }
        guard document.recoveryConfirmedAt == nil else { throw VaultSetupError.alreadyExists }
        guard let masterKey = try VaultMasterKeyStore.load(
            ownerUID: ownerUID,
            version: document.passphraseEnvelope.masterKeyVersion
        ) else {
            throw VaultSetupError.missingLocalMasterKey
        }
        let recoveryKey = try VaultRecoveryKey.generate()
        let replacementCreatedAt = persistedTimestamp()
        document = LocalVaultEnvelopeDocument(
            ownerUID: ownerUID,
            passphraseEnvelope: document.passphraseEnvelope,
            recoveryEnvelope: try VaultKeyEnvelopeCrypto.sealWithRecoveryKey(
                masterKey: masterKey,
                ownerUID: ownerUID,
                recoveryKey: recoveryKey,
                createdAt: replacementCreatedAt
            ),
            createdAt: document.createdAt
        )
        try envelopeStore.save(document)
        return LocalVaultCreation(document: document, recoveryKey: recoveryKey.exportString)
    }

    static func summary(
        ownerUID: String,
        envelopeStore: VaultEnvelopeStore = VaultEnvelopeStore()
    ) throws -> LocalVaultSummary? {
        guard let document = try envelopeStore.load(ownerUID: ownerUID) else { return nil }
        return LocalVaultSummary(
            createdAt: document.createdAt,
            keyVersion: document.passphraseEnvelope.masterKeyVersion,
            recoveryConfirmed: document.recoveryConfirmedAt != nil
        )
    }

    @discardableResult
    static func restoreWithPassphrase(
        ownerUID: String,
        document: LocalVaultEnvelopeDocument,
        passphrase: String,
        envelopeStore: VaultEnvelopeStore = VaultEnvelopeStore()
    ) throws -> VaultMasterKey {
        try validate(document: document, ownerUID: ownerUID)
        let masterKey = try VaultKeyEnvelopeCrypto.openWithPassphrase(
            document.passphraseEnvelope,
            ownerUID: ownerUID,
            passphrase: passphrase
        )
        try persistRestored(
            masterKey: masterKey,
            document: document,
            ownerUID: ownerUID,
            envelopeStore: envelopeStore
        )
        return masterKey
    }

    @discardableResult
    static func restoreWithRecoveryKey(
        ownerUID: String,
        document: LocalVaultEnvelopeDocument,
        recoveryKeyString: String,
        envelopeStore: VaultEnvelopeStore = VaultEnvelopeStore()
    ) throws -> VaultMasterKey {
        try validate(document: document, ownerUID: ownerUID)
        let recoveryKey = try VaultRecoveryKey(exportString: recoveryKeyString)
        let masterKey = try VaultKeyEnvelopeCrypto.openWithRecoveryKey(
            document.recoveryEnvelope,
            ownerUID: ownerUID,
            recoveryKey: recoveryKey
        )
        try persistRestored(
            masterKey: masterKey,
            document: document,
            ownerUID: ownerUID,
            envelopeStore: envelopeStore
        )
        return masterKey
    }

    private static func validate(document: LocalVaultEnvelopeDocument, ownerUID: String) throws {
        guard !ownerUID.isEmpty else { throw VaultSetupError.invalidOwner }
        guard document.schemaVersion == LocalVaultEnvelopeDocument.currentSchemaVersion else {
            throw VaultSetupError.unsupportedDocument
        }
        guard document.ownerUID == ownerUID else { throw VaultSetupError.ownerMismatch }
        guard document.passphraseEnvelope.wrappingMethod == .passphrase,
              document.recoveryEnvelope.wrappingMethod == .recoveryKey,
              document.passphraseEnvelope.masterKeyVersion == document.recoveryEnvelope.masterKeyVersion else {
            throw VaultSetupError.unsupportedDocument
        }
    }

    private static func persistRestored(
        masterKey: VaultMasterKey,
        document: LocalVaultEnvelopeDocument,
        ownerUID: String,
        envelopeStore: VaultEnvelopeStore
    ) throws {
        let existingKey = try VaultMasterKeyStore.load(ownerUID: ownerUID, version: masterKey.version)
        if let existingKey, existingKey != masterKey {
            throw VaultSetupError.ownerMismatch
        }
        if existingKey == nil {
            try VaultMasterKeyStore.save(masterKey, ownerUID: ownerUID)
        }
        do {
            try envelopeStore.save(document)
        } catch {
            if existingKey == nil {
                _ = try? VaultMasterKeyStore.delete(ownerUID: ownerUID, version: masterKey.version)
            }
            throw error
        }
    }

    private static func persistedTimestamp() -> Date {
        let milliseconds = (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

private extension JSONEncoder {
    static var vaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var vaultDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
