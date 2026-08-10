import Foundation

enum VaultWrappingMethod: String, Codable, Sendable {
    case passphrase
    case recoveryKey
}

struct VaultKeyDerivationParameters: Codable, Equatable, Sendable {
    let algorithm: String
    let salt: Data
    let operationsLimit: UInt64
    let memoryLimitBytes: UInt64
}

/// Cloud-safe envelope. It contains only an encrypted Master Key and the
/// public parameters required to derive its wrapping key.
struct VaultKeyEnvelope: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let wrappingMethod: VaultWrappingMethod
    let derivation: VaultKeyDerivationParameters
    let ciphertext: Data
    let nonce: Data
    let authenticationTag: Data
    let masterKeyVersion: UInt32
    let formatVersion: UInt32
    let createdAt: Date
}

struct VaultRecordContext: Equatable, Sendable {
    let ownerUID: String
    let recordID: UUID
    let recordType: SyncRecordType
    let keyVersion: UInt32
    let formatVersion: UInt32
    let revision: UInt64
    let modifiedAt: Date
    let modifiedByDeviceID: UUID
    let deleted: Bool
}
