import CryptoKit
import Foundation
import Security
import Sodium

enum VaultCryptoError: LocalizedError, Equatable {
    case invalidOwner
    case invalidMasterKey
    case randomGenerationFailed(OSStatus)
    case unsupportedFormat
    case unsupportedKeyVersion
    case invalidMetadata
    case encryptionFailed
    case authenticationFailed
    case invalidPassphrase
    case invalidRecoveryKey
    case invalidDerivationParameters
    case keyDerivationFailed
    case wrongWrappingMethod

    var errorDescription: String? {
        switch self {
        case .invalidOwner: "加密保管庫缺少有效的帳號識別。"
        case .invalidMasterKey: "加密保管庫主金鑰格式不正確。"
        case .randomGenerationFailed(let status): "無法產生加密安全亂數（\(status)）。"
        case .unsupportedFormat: "這份加密資料使用尚未支援的格式版本。"
        case .unsupportedKeyVersion: "找不到這份資料所需的主金鑰版本。"
        case .invalidMetadata: "加密資料的識別資訊不正確。"
        case .encryptionFailed: "無法加密同步資料。"
        case .authenticationFailed: "加密資料驗證失敗，資料可能已損毀或不屬於這個帳號。"
        case .invalidPassphrase: "同步密語格式不符合安全要求。"
        case .invalidRecoveryKey: "復原金鑰格式不正確。"
        case .invalidDerivationParameters: "加密封套的金鑰衍生參數不安全或不受支援。"
        case .keyDerivationFailed: "無法從同步密語衍生加密金鑰。"
        case .wrongWrappingMethod: "加密封套與目前選擇的復原方式不相符。"
        }
    }
}

enum VaultCryptoFormat {
    static let recordVersion: UInt32 = 1
    static let envelopeVersion: UInt32 = 1
    static let masterKeyVersion: UInt32 = 1
    static let argon2Algorithm = "argon2id13"
    static let recoveryAlgorithm = "hkdf-sha256"
    static let argon2Operations: UInt64 = 3
    static let argon2MemoryBytes: UInt64 = 64 * 1024 * 1024
    static let saltByteCount = 16
}

enum VaultRecordCrypto {
    static func encrypt(
        _ plaintext: Data,
        context: VaultRecordContext,
        masterKey: VaultMasterKey,
        nonce: Data? = nil
    ) throws -> EncryptedSyncRecord {
        try validate(context: context, masterKey: masterKey)
        let aad = try recordAAD(context)
        let recordKey = deriveRecordKey(masterKey: masterKey, aad: aad)
        do {
            let sealed: AES.GCM.SealedBox
            if let nonce {
                sealed = try AES.GCM.seal(
                    plaintext,
                    using: recordKey,
                    nonce: try AES.GCM.Nonce(data: nonce),
                    authenticating: aad
                )
            } else {
                sealed = try AES.GCM.seal(plaintext, using: recordKey, authenticating: aad)
            }
            return EncryptedSyncRecord(
                id: context.recordID,
                recordType: context.recordType,
                ciphertext: sealed.ciphertext,
                nonce: sealed.nonce.withUnsafeBytes { Data($0) },
                authenticationTag: sealed.tag,
                keyVersion: context.keyVersion,
                formatVersion: context.formatVersion,
                revision: context.revision,
                modifiedAt: context.modifiedAt,
                modifiedByDeviceID: context.modifiedByDeviceID,
                deleted: context.deleted
            )
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.encryptionFailed
        }
    }

    static func decrypt(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> Data {
        let context = VaultRecordContext(
            ownerUID: ownerUID,
            recordID: record.id,
            recordType: record.recordType,
            keyVersion: record.keyVersion,
            formatVersion: record.formatVersion,
            revision: record.revision,
            modifiedAt: record.modifiedAt,
            modifiedByDeviceID: record.modifiedByDeviceID,
            deleted: record.deleted
        )
        try validate(context: context, masterKey: masterKey)
        let aad = try recordAAD(context)
        let recordKey = deriveRecordKey(masterKey: masterKey, aad: aad)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: record.nonce),
                ciphertext: record.ciphertext,
                tag: record.authenticationTag
            )
            return try AES.GCM.open(box, using: recordKey, authenticating: aad)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    static func recordAAD(_ context: VaultRecordContext) throws -> Data {
        guard !context.ownerUID.isEmpty else { throw VaultCryptoError.invalidOwner }
        var builder = VaultBinaryEncoding(domain: "MyTerm.Record.AAD.v1")
        try builder.append(context.ownerUID)
        builder.append(context.recordID)
        try builder.append(context.recordType.rawValue)
        builder.append(context.formatVersion)
        builder.append(context.keyVersion)
        builder.append(context.revision)
        builder.append(context.modifiedByDeviceID)
        builder.append(context.deleted)
        return builder.data
    }

    private static func validate(context: VaultRecordContext, masterKey: VaultMasterKey) throws {
        guard context.formatVersion == VaultCryptoFormat.recordVersion else {
            throw VaultCryptoError.unsupportedFormat
        }
        guard context.keyVersion == masterKey.version else {
            throw VaultCryptoError.unsupportedKeyVersion
        }
        guard context.revision > 0 else { throw VaultCryptoError.invalidMetadata }
    }

    private static func deriveRecordKey(masterKey: VaultMasterKey, aad: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey.rawRepresentation),
            salt: Data("MyTerm.Record.HKDF.v1".utf8),
            info: aad,
            outputByteCount: VaultMasterKey.byteCount
        )
    }
}

struct VaultRecoveryKey: Equatable, Sendable {
    private static let prefix = "MYTERM-R1-"
    private let bytes: Data

    init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == VaultMasterKey.byteCount else {
            throw VaultCryptoError.invalidRecoveryKey
        }
        bytes = rawRepresentation
    }

    static func generate() throws -> Self {
        try Self(rawRepresentation: VaultRandom.data(count: VaultMasterKey.byteCount))
    }

    init(exportString: String) throws {
        guard exportString.hasPrefix(Self.prefix),
              let decoded = VaultBase64URL.decode(String(exportString.dropFirst(Self.prefix.count))) else {
            throw VaultCryptoError.invalidRecoveryKey
        }
        try self.init(rawRepresentation: decoded)
    }

    var exportString: String { Self.prefix + VaultBase64URL.encode(bytes) }
    fileprivate var rawRepresentation: Data { bytes }
}

enum VaultKeyEnvelopeCrypto {
    static func sealWithPassphrase(
        masterKey: VaultMasterKey,
        ownerUID: String,
        passphrase: String,
        envelopeID: UUID = UUID(),
        salt: Data? = nil,
        nonce: Data? = nil,
        createdAt: Date = .now
    ) throws -> VaultKeyEnvelope {
        guard passphrase.count >= 12 else { throw VaultCryptoError.invalidPassphrase }
        let parameters = VaultKeyDerivationParameters(
            algorithm: VaultCryptoFormat.argon2Algorithm,
            salt: try salt ?? VaultRandom.data(count: VaultCryptoFormat.saltByteCount),
            operationsLimit: VaultCryptoFormat.argon2Operations,
            memoryLimitBytes: VaultCryptoFormat.argon2MemoryBytes
        )
        let wrappingKey = try derivePassphraseKey(passphrase, parameters: parameters)
        return try seal(
            masterKey: masterKey,
            ownerUID: ownerUID,
            method: .passphrase,
            parameters: parameters,
            wrappingKey: wrappingKey,
            envelopeID: envelopeID,
            nonce: nonce,
            createdAt: createdAt
        )
    }

    static func openWithPassphrase(
        _ envelope: VaultKeyEnvelope,
        ownerUID: String,
        passphrase: String
    ) throws -> VaultMasterKey {
        guard envelope.wrappingMethod == .passphrase else {
            throw VaultCryptoError.wrongWrappingMethod
        }
        let wrappingKey = try derivePassphraseKey(passphrase, parameters: envelope.derivation)
        return try open(envelope, ownerUID: ownerUID, wrappingKey: wrappingKey)
    }

    static func sealWithRecoveryKey(
        masterKey: VaultMasterKey,
        ownerUID: String,
        recoveryKey: VaultRecoveryKey,
        envelopeID: UUID = UUID(),
        salt: Data? = nil,
        nonce: Data? = nil,
        createdAt: Date = .now
    ) throws -> VaultKeyEnvelope {
        let parameters = VaultKeyDerivationParameters(
            algorithm: VaultCryptoFormat.recoveryAlgorithm,
            salt: try salt ?? VaultRandom.data(count: VaultCryptoFormat.saltByteCount),
            operationsLimit: 0,
            memoryLimitBytes: 0
        )
        let wrappingKey = try deriveRecoveryKey(recoveryKey, parameters: parameters)
        return try seal(
            masterKey: masterKey,
            ownerUID: ownerUID,
            method: .recoveryKey,
            parameters: parameters,
            wrappingKey: wrappingKey,
            envelopeID: envelopeID,
            nonce: nonce,
            createdAt: createdAt
        )
    }

    static func openWithRecoveryKey(
        _ envelope: VaultKeyEnvelope,
        ownerUID: String,
        recoveryKey: VaultRecoveryKey
    ) throws -> VaultMasterKey {
        guard envelope.wrappingMethod == .recoveryKey else {
            throw VaultCryptoError.wrongWrappingMethod
        }
        let wrappingKey = try deriveRecoveryKey(recoveryKey, parameters: envelope.derivation)
        return try open(envelope, ownerUID: ownerUID, wrappingKey: wrappingKey)
    }

    static func envelopeAAD(
        envelopeID: UUID,
        ownerUID: String,
        method: VaultWrappingMethod,
        parameters: VaultKeyDerivationParameters,
        masterKeyVersion: UInt32,
        formatVersion: UInt32
    ) throws -> Data {
        guard !ownerUID.isEmpty else { throw VaultCryptoError.invalidOwner }
        var builder = VaultBinaryEncoding(domain: "MyTerm.Envelope.AAD.v1")
        builder.append(envelopeID)
        try builder.append(ownerUID)
        try builder.append(method.rawValue)
        try builder.append(parameters.algorithm)
        try builder.append(parameters.salt)
        builder.append(parameters.operationsLimit)
        builder.append(parameters.memoryLimitBytes)
        builder.append(masterKeyVersion)
        builder.append(formatVersion)
        return builder.data
    }

    private static func seal(
        masterKey: VaultMasterKey,
        ownerUID: String,
        method: VaultWrappingMethod,
        parameters: VaultKeyDerivationParameters,
        wrappingKey: SymmetricKey,
        envelopeID: UUID,
        nonce: Data?,
        createdAt: Date
    ) throws -> VaultKeyEnvelope {
        let aad = try envelopeAAD(
            envelopeID: envelopeID,
            ownerUID: ownerUID,
            method: method,
            parameters: parameters,
            masterKeyVersion: masterKey.version,
            formatVersion: VaultCryptoFormat.envelopeVersion
        )
        do {
            let sealed: AES.GCM.SealedBox
            if let nonce {
                sealed = try AES.GCM.seal(
                    masterKey.rawRepresentation,
                    using: wrappingKey,
                    nonce: try AES.GCM.Nonce(data: nonce),
                    authenticating: aad
                )
            } else {
                sealed = try AES.GCM.seal(
                    masterKey.rawRepresentation,
                    using: wrappingKey,
                    authenticating: aad
                )
            }
            return VaultKeyEnvelope(
                id: envelopeID,
                wrappingMethod: method,
                derivation: parameters,
                ciphertext: sealed.ciphertext,
                nonce: sealed.nonce.withUnsafeBytes { Data($0) },
                authenticationTag: sealed.tag,
                masterKeyVersion: masterKey.version,
                formatVersion: VaultCryptoFormat.envelopeVersion,
                createdAt: createdAt
            )
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.encryptionFailed
        }
    }

    private static func open(
        _ envelope: VaultKeyEnvelope,
        ownerUID: String,
        wrappingKey: SymmetricKey
    ) throws -> VaultMasterKey {
        guard envelope.formatVersion == VaultCryptoFormat.envelopeVersion else {
            throw VaultCryptoError.unsupportedFormat
        }
        let aad = try envelopeAAD(
            envelopeID: envelope.id,
            ownerUID: ownerUID,
            method: envelope.wrappingMethod,
            parameters: envelope.derivation,
            masterKeyVersion: envelope.masterKeyVersion,
            formatVersion: envelope.formatVersion
        )
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext,
                tag: envelope.authenticationTag
            )
            let rawKey = try AES.GCM.open(box, using: wrappingKey, authenticating: aad)
            return try VaultMasterKey(rawRepresentation: rawKey, version: envelope.masterKeyVersion)
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    private static func derivePassphraseKey(
        _ passphrase: String,
        parameters: VaultKeyDerivationParameters
    ) throws -> SymmetricKey {
        guard parameters.algorithm == VaultCryptoFormat.argon2Algorithm,
              parameters.salt.count == VaultCryptoFormat.saltByteCount,
              (1...10).contains(parameters.operationsLimit),
              (8 * 1024 * 1024...1024 * 1024 * 1024).contains(parameters.memoryLimitBytes),
              let opsLimit = Int(exactly: parameters.operationsLimit),
              let memoryLimit = Int(exactly: parameters.memoryLimitBytes),
              !passphrase.isEmpty else {
            throw VaultCryptoError.invalidDerivationParameters
        }
        let sodium = Sodium()
        var passwordBytes = Array(passphrase.utf8)
        defer { sodium.utils.zero(&passwordBytes) }
        guard var derived = sodium.pwHash.hash(
            outputLength: VaultMasterKey.byteCount,
            passwd: passwordBytes,
            salt: Array(parameters.salt),
            opsLimit: opsLimit,
            memLimit: memoryLimit,
            alg: .Argon2ID13
        ) else {
            throw VaultCryptoError.keyDerivationFailed
        }
        defer { sodium.utils.zero(&derived) }
        return SymmetricKey(data: derived)
    }

    private static func deriveRecoveryKey(
        _ recoveryKey: VaultRecoveryKey,
        parameters: VaultKeyDerivationParameters
    ) throws -> SymmetricKey {
        guard parameters.algorithm == VaultCryptoFormat.recoveryAlgorithm,
              parameters.salt.count == VaultCryptoFormat.saltByteCount,
              parameters.operationsLimit == 0,
              parameters.memoryLimitBytes == 0 else {
            throw VaultCryptoError.invalidDerivationParameters
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoveryKey.rawRepresentation),
            salt: parameters.salt,
            info: Data("MyTerm.Recovery.Wrap.v1".utf8),
            outputByteCount: VaultMasterKey.byteCount
        )
    }
}

private enum VaultRandom {
    static func data(count: Int) throws -> Data {
        guard count > 0 else { throw VaultCryptoError.invalidMetadata }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw VaultCryptoError.randomGenerationFailed(status)
        }
        defer {
            _ = bytes.withUnsafeMutableBytes { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        return Data(bytes)
    }
}

private enum VaultBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

private struct VaultBinaryEncoding {
    private(set) var data: Data

    init(domain: String) {
        data = Data(domain.utf8)
        data.append(0)
    }

    mutating func append(_ value: String) throws {
        try append(Data(value.utf8))
    }

    mutating func append(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else { throw VaultCryptoError.invalidMetadata }
        append(UInt32(value.count))
        data.append(value)
    }

    mutating func append(_ value: UUID) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
