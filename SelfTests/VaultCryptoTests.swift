import Foundation
import Security

private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        passed += 1
        print("PASS: \(name)")
    } else {
        failed += 1
        print("FAIL: \(name)")
    }
}

private func checkThrows(
    _ expected: VaultCryptoError,
    _ name: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        check(false, name)
    } catch let error as VaultCryptoError {
        check(error == expected, name)
    } catch {
        check(false, "\(name): \(error)")
    }
}

private func checkThrowing(_ name: String, condition: () throws -> Bool) {
    do {
        let result = try condition()
        check(result, name)
    } catch {
        check(false, "\(name): \(error)")
    }
}

private func checkMetadataThrows(
    _ expected: MetadataSyncCodecError,
    _ name: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        check(false, name)
    } catch let error as MetadataSyncCodecError {
        check(error == expected, name)
    } catch {
        check(false, "\(name): \(error)")
    }
}

private func checkFirestoreMetadataThrows(
    _ expected: FirestoreMetadataBackendError,
    _ name: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        check(false, name)
    } catch let error as FirestoreMetadataBackendError {
        check(error == expected, name)
    } catch {
        check(false, "\(name): \(error)")
    }
}

private func checkMetadataPreviewThrows(
    _ expected: MetadataSyncPreviewError,
    _ name: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        check(false, name)
    } catch let error as MetadataSyncPreviewError {
        check(error == expected, name)
    } catch {
        check(false, "\(name): \(error)")
    }
}

private func checkCloudRestoreThrows(
    _ expected: CloudInventoryRestoreError,
    _ name: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        check(false, name)
    } catch let error as CloudInventoryRestoreError {
        check(error == expected, name)
    } catch {
        check(false, "\(name): \(error)")
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

let ownerUID = "firebase-test-user"
let recordID = UUID(uuidString: "10000000-2000-3000-4000-500000000001")!
let deviceID = UUID(uuidString: "90000000-8000-7000-6000-500000000001")!
let envelopeID = UUID(uuidString: "a0000000-b000-c000-d000-e00000000001")!
let fixedDate = Date(timeIntervalSince1970: 1_786_118_400)

@main
enum VaultCryptoTestRunner {
static func main() {
do {
    let masterKey = try VaultMasterKey(rawRepresentation: Data(0..<32), version: 1)
    let context = VaultRecordContext(
        ownerUID: ownerUID,
        recordID: recordID,
        recordType: .host,
        keyVersion: 1,
        formatVersion: 1,
        revision: 7,
        modifiedAt: fixedDate,
        modifiedByDeviceID: deviceID,
        deleted: false
    )
    let plaintext = Data(#"{"hostname":"192.0.2.10","port":22}"#.utf8)
    let nonce = Data([0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab])
    let encrypted = try VaultRecordCrypto.encrypt(
        plaintext,
        context: context,
        masterKey: masterKey,
        nonce: nonce
    )
    let repeated = try VaultRecordCrypto.encrypt(
        plaintext,
        context: context,
        masterKey: masterKey,
        nonce: nonce
    )
    check(encrypted == repeated, "fixed record inputs produce a stable AES-GCM fixture")
    check(encrypted.nonce == nonce, "record encryption preserves the supplied test nonce")
    check(
        encrypted.ciphertext.hex == "50f870c9c185719a2b83a2980dc2dd819686d4e9691efc1b7f81346ed2a6de3de4b356",
        "record ciphertext matches the fixed v1 test vector"
    )
    check(
        encrypted.authenticationTag.hex == "d276002c95986e1382c6e327e9a8cbb0",
        "record authentication tag matches the fixed v1 test vector"
    )
    checkThrowing("record ciphertext decrypts to the original plaintext") {
        try VaultRecordCrypto.decrypt(encrypted, ownerUID: ownerUID, masterKey: masterKey) == plaintext
    }

    checkThrows(.authenticationFailed, "record AAD rejects a different Firebase UID") {
        _ = try VaultRecordCrypto.decrypt(encrypted, ownerUID: "other-user", masterKey: masterKey)
    }

    var corruptedCiphertext = encrypted.ciphertext
    corruptedCiphertext[corruptedCiphertext.startIndex] ^= 0x01
    let corrupted = EncryptedSyncRecord(
        id: encrypted.id,
        recordType: encrypted.recordType,
        ciphertext: corruptedCiphertext,
        nonce: encrypted.nonce,
        authenticationTag: encrypted.authenticationTag,
        keyVersion: encrypted.keyVersion,
        formatVersion: encrypted.formatVersion,
        revision: encrypted.revision,
        modifiedAt: encrypted.modifiedAt,
        modifiedByDeviceID: encrypted.modifiedByDeviceID,
        deleted: encrypted.deleted
    )
    checkThrows(.authenticationFailed, "record authentication rejects altered ciphertext") {
        _ = try VaultRecordCrypto.decrypt(corrupted, ownerUID: ownerUID, masterKey: masterKey)
    }

    let forgedDeletion = EncryptedSyncRecord(
        id: encrypted.id,
        recordType: encrypted.recordType,
        ciphertext: encrypted.ciphertext,
        nonce: encrypted.nonce,
        authenticationTag: encrypted.authenticationTag,
        keyVersion: encrypted.keyVersion,
        formatVersion: encrypted.formatVersion,
        revision: encrypted.revision,
        modifiedAt: encrypted.modifiedAt,
        modifiedByDeviceID: encrypted.modifiedByDeviceID,
        deleted: true
    )
    checkThrows(.authenticationFailed, "record AAD rejects a forged deletion marker") {
        _ = try VaultRecordCrypto.decrypt(forgedDeletion, ownerUID: ownerUID, masterKey: masterKey)
    }
} catch {
    check(false, "record encryption suite: \(error)")
}

do {
    let uid = "vault-key-test-\(UUID().uuidString)"
    let key = try VaultMasterKey.generate()
    defer { _ = try? VaultMasterKeyStore.delete(ownerUID: uid, version: key.version) }
    try VaultMasterKeyStore.save(key, ownerUID: uid)
    checkThrowing("Master Key survives a Keychain round trip") {
        try VaultMasterKeyStore.load(ownerUID: uid, version: key.version) == key
    }
    checkThrowing("Master Key uses WhenUnlockedThisDeviceOnly Keychain accessibility") {
        try VaultMasterKeyStore.usesThisDeviceOnlyAccessibility(ownerUID: uid, version: key.version)
    }
    checkThrowing("Master Key is removed from Keychain") {
        try VaultMasterKeyStore.delete(ownerUID: uid, version: key.version) == .removed
    }
    checkThrowing("removed Master Key cannot be loaded") {
        try VaultMasterKeyStore.load(ownerUID: uid, version: key.version) == nil
    }
} catch {
    check(false, "Master Key Keychain suite: \(error)")
}

do {
    let masterKey = try VaultMasterKey(rawRepresentation: Data(0..<32), version: 1)
    let passphrase = "correct horse battery staple"
    let envelope = try VaultKeyEnvelopeCrypto.sealWithPassphrase(
        masterKey: masterKey,
        ownerUID: ownerUID,
        passphrase: passphrase,
        envelopeID: envelopeID,
        salt: Data(16..<32),
        nonce: Data(repeating: 0x22, count: 12),
        createdAt: fixedDate
    )
    check(envelope.derivation.algorithm == "argon2id13", "passphrase envelope records Argon2id v1.3")
    check(envelope.derivation.operationsLimit == 3, "passphrase envelope records its operations limit")
    check(
        envelope.derivation.memoryLimitBytes == 64 * 1024 * 1024,
        "passphrase envelope records its 64 MiB memory limit"
    )
    checkThrowing("correct passphrase unwraps the Master Key") {
        try VaultKeyEnvelopeCrypto.openWithPassphrase(
            envelope,
            ownerUID: ownerUID,
            passphrase: passphrase
        ) == masterKey
    }
    checkThrows(.authenticationFailed, "wrong passphrase cannot unwrap the Master Key") {
        _ = try VaultKeyEnvelopeCrypto.openWithPassphrase(
            envelope,
            ownerUID: ownerUID,
            passphrase: "a completely wrong passphrase"
        )
    }
    checkThrows(.authenticationFailed, "passphrase envelope is bound to the Firebase UID") {
        _ = try VaultKeyEnvelopeCrypto.openWithPassphrase(
            envelope,
            ownerUID: "other-user",
            passphrase: passphrase
        )
    }
} catch {
    check(false, "passphrase envelope suite: \(error)")
}

do {
    let masterKey = try VaultMasterKey(rawRepresentation: Data(0..<32), version: 1)
    let recovery = try VaultRecoveryKey(
        rawRepresentation: Data((0..<32).map { UInt8(255 - $0) })
    )
    let exported = recovery.exportString
    check(exported.hasPrefix("MYTERM-R1-"), "recovery key export is explicitly versioned")
    checkThrowing("recovery key export round trip succeeds") {
        try VaultRecoveryKey(exportString: exported) == recovery
    }

    let envelope = try VaultKeyEnvelopeCrypto.sealWithRecoveryKey(
        masterKey: masterKey,
        ownerUID: ownerUID,
        recoveryKey: recovery,
        envelopeID: envelopeID,
        salt: Data(32..<48),
        nonce: Data(repeating: 0x33, count: 12),
        createdAt: fixedDate
    )
    checkThrowing("recovery key unwraps the Master Key") {
        try VaultKeyEnvelopeCrypto.openWithRecoveryKey(
            envelope,
            ownerUID: ownerUID,
            recoveryKey: recovery
        ) == masterKey
    }
    let wrongRecovery = try VaultRecoveryKey(rawRepresentation: Data(repeating: 0x44, count: 32))
    checkThrows(.authenticationFailed, "wrong recovery key cannot unwrap the Master Key") {
        _ = try VaultKeyEnvelopeCrypto.openWithRecoveryKey(
            envelope,
            ownerUID: ownerUID,
            recoveryKey: wrongRecovery
        )
    }

    let data = try JSONEncoder().encode(envelope)
    let json = String(decoding: data, as: UTF8.self)
    check(
        !json.contains(masterKey.rawRepresentation.base64EncodedString()),
        "serialized envelope excludes the plaintext Master Key"
    )
    check(!json.contains(recovery.exportString), "serialized envelope excludes the recovery key")
    checkThrowing("versioned envelope survives serialization") {
        try JSONDecoder().decode(VaultKeyEnvelope.self, from: data) == envelope
    }
} catch {
    check(false, "recovery envelope suite: \(error)")
}

do {
    let unsafeEnvelope = VaultKeyEnvelope(
        id: envelopeID,
        wrappingMethod: .passphrase,
        derivation: VaultKeyDerivationParameters(
            algorithm: "argon2id13",
            salt: Data(repeating: 0, count: 16),
            operationsLimit: 1_000_000,
            memoryLimitBytes: UInt64.max
        ),
        ciphertext: Data(repeating: 0, count: 32),
        nonce: Data(repeating: 0, count: 12),
        authenticationTag: Data(repeating: 0, count: 16),
        masterKeyVersion: 1,
        formatVersion: 1,
        createdAt: fixedDate
    )
    checkThrows(.invalidDerivationParameters, "unsafe cloud KDF parameters are rejected before allocation") {
        _ = try VaultKeyEnvelopeCrypto.openWithPassphrase(
            unsafeEnvelope,
            ownerUID: ownerUID,
            passphrase: "correct horse battery staple"
        )
    }
}

do {
    let uid = "vault-setup-test-\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-VaultSetup-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = VaultEnvelopeStore(directory: directory)
    let passphrase = "five correct unrelated words are safer"
    defer {
        _ = try? VaultMasterKeyStore.delete(ownerUID: uid, version: VaultCryptoFormat.masterKeyVersion)
        try? FileManager.default.removeItem(at: directory)
    }

    let creation = try VaultSetupService.create(
        ownerUID: uid,
        passphrase: passphrase,
        envelopeStore: store
    )
    check(creation.recoveryKey.hasPrefix("MYTERM-R1-"), "vault setup returns a versioned recovery key")
    checkThrowing("vault setup persists its Master Key in Keychain") {
        try VaultMasterKeyStore.load(ownerUID: uid, version: VaultCryptoFormat.masterKeyVersion) != nil
    }
    checkThrowing("vault envelope document survives a local round trip") {
        try store.load(ownerUID: uid) == creation.document
    }
    checkThrowing("local vault envelope file is owner-only") {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL(ownerUID: uid).path
        )
        guard let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o777 == 0o600
    }
    checkThrowing("local vault file excludes passphrase and recovery key plaintext") {
        let data = try Data(contentsOf: store.fileURL(ownerUID: uid))
        let text = String(decoding: data, as: UTF8.self)
        return !text.contains(passphrase) && !text.contains(creation.recoveryKey)
    }

    let firstRecovery = try VaultRecoveryKey(exportString: creation.recoveryKey)
    let replacement = try VaultSetupService.replaceUnconfirmedRecoveryKey(
        ownerUID: uid,
        envelopeStore: store
    )
    check(replacement.recoveryKey != creation.recoveryKey, "unconfirmed recovery key is replaced instead of redisplayed")
    checkThrows(.authenticationFailed, "replaced recovery envelope rejects the previous recovery key") {
        _ = try VaultKeyEnvelopeCrypto.openWithRecoveryKey(
            replacement.document.recoveryEnvelope,
            ownerUID: uid,
            recoveryKey: firstRecovery
        )
    }

    let confirmed = try VaultSetupService.confirmRecoveryKey(ownerUID: uid, envelopeStore: store)
    check(confirmed.recoveryConfirmedAt != nil, "recovery confirmation is persisted")
    checkThrowing("confirmed vault summary is ready") {
        try VaultSetupService.summary(ownerUID: uid, envelopeStore: store)?.recoveryConfirmed == true
    }

    guard let expectedMasterKey = try VaultMasterKeyStore.load(
        ownerUID: uid,
        version: VaultCryptoFormat.masterKeyVersion
    ) else {
        throw VaultSetupError.missingLocalMasterKey
    }
    _ = try VaultMasterKeyStore.delete(ownerUID: uid, version: VaultCryptoFormat.masterKeyVersion)
    checkThrows(.authenticationFailed, "wrong sync passphrase cannot restore a missing device key") {
        _ = try VaultSetupService.restoreWithPassphrase(
            ownerUID: uid,
            document: confirmed,
            passphrase: "this is definitely the wrong passphrase",
            envelopeStore: store
        )
    }
    checkThrowing("wrong sync passphrase leaves Keychain empty") {
        try VaultMasterKeyStore.load(ownerUID: uid, version: VaultCryptoFormat.masterKeyVersion) == nil
    }
    checkThrowing("correct sync passphrase restores the same Master Key") {
        try VaultSetupService.restoreWithPassphrase(
            ownerUID: uid,
            document: confirmed,
            passphrase: passphrase,
            envelopeStore: store
        ) == expectedMasterKey
    }
    checkThrowing("restored passphrase key uses ThisDeviceOnly accessibility") {
        try VaultMasterKeyStore.usesThisDeviceOnlyAccessibility(
            ownerUID: uid,
            version: VaultCryptoFormat.masterKeyVersion
        )
    }

    _ = try VaultMasterKeyStore.delete(ownerUID: uid, version: VaultCryptoFormat.masterKeyVersion)
    let wrongRecoveryKey = try VaultRecoveryKey.generate().exportString
    checkThrows(.authenticationFailed, "wrong recovery key cannot restore a missing device key") {
        _ = try VaultSetupService.restoreWithRecoveryKey(
            ownerUID: uid,
            document: confirmed,
            recoveryKeyString: wrongRecoveryKey,
            envelopeStore: store
        )
    }
    checkThrowing("wrong recovery key leaves Keychain empty") {
        try VaultMasterKeyStore.load(ownerUID: uid, version: VaultCryptoFormat.masterKeyVersion) == nil
    }
    checkThrowing("correct recovery key restores the same Master Key") {
        try VaultSetupService.restoreWithRecoveryKey(
            ownerUID: uid,
            document: confirmed,
            recoveryKeyString: replacement.recoveryKey,
            envelopeStore: store
        ) == expectedMasterKey
    }

    let backend = FirestoreVaultBackend(
        projectID: "demo-myterm",
        apiRoot: URL(string: "http://127.0.0.1:8080/v1")!
    )
    let idToken = "test-firebase-id-token"
    let fetchRequest = try backend.fetchRequest(ownerUID: uid, idToken: idToken)
    check(fetchRequest.httpMethod == "GET", "Firestore envelope fetch uses GET")
    check(
        fetchRequest.url?.path.hasSuffix("/users/\(uid)/vaultKeys/current") == true,
        "Firestore envelope path is scoped to the Firebase UID and fixed current document"
    )
    check(
        fetchRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(idToken)",
        "Firestore envelope fetch uses the Firebase ID token"
    )

    let upsertRequest = try backend.upsertRequest(confirmed, ownerUID: uid, idToken: idToken)
    check(upsertRequest.httpMethod == "PATCH", "Firestore envelope upsert uses PATCH")
    checkThrowing("Firestore envelope response decodes to the original local document") {
        guard let body = upsertRequest.httpBody else { return false }
        return try backend.decodeDocument(body, expectedOwnerUID: uid) == confirmed
    }
    checkThrowing("Firestore request body contains no sync passphrase or recovery key plaintext") {
        guard let body = upsertRequest.httpBody else { return false }
        let bodyText = String(decoding: body, as: UTF8.self)
        return !bodyText.contains(passphrase) && !bodyText.contains(replacement.recoveryKey)
    }
    checkThrowing("Firestore response is rejected when assigned to another Firebase UID") {
        guard let body = upsertRequest.httpBody else { return false }
        do {
            _ = try backend.decodeDocument(body, expectedOwnerUID: "different-user")
            return false
        } catch let error as FirestoreVaultBackendError {
            return error == .invalidResponse
        }
    }
} catch {
    check(false, "local vault setup suite: \(error)")
}

do {
    let masterKey = try VaultMasterKey(rawRepresentation: Data(0..<32), version: 1)
    let metadataOwner = "firebase-metadata-user"
    let metadataDevice = UUID(uuidString: "70000000-8000-9000-a000-b00000000001")!
    let group = HostGroup(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
        name: "Production / Network",
        createdAt: fixedDate
    )
    let encryptedGroup = try MetadataSyncCodec.encrypt(
        group: group,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 1,
        modifiedByDeviceID: metadataDevice,
        nonce: Data(repeating: 0x51, count: 12)
    )
    checkThrowing("encrypted group metadata round trips without changing hierarchy fields") {
        try MetadataSyncCodec.decrypt(
            encryptedGroup,
            ownerUID: metadataOwner,
            masterKey: masterKey
        ) == .group(group)
    }

    var host = HostProfile()
    host.id = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    host.name = "Core Router"
    host.hostname = "router.example.internal"
    host.port = 2222
    host.username = "network-admin"
    host.groupID = group.id
    host.notes = "Metadata only; no password."
    host.authenticationMethod = .privateKey
    host.privateKeyPath = "/Users/tester/.ssh/id_private_should_never_sync"
    host.algorithmMode = .rsaCompatibility
    host.detectedPlatform = .cisco
    host.createdAt = fixedDate
    host.updatedAt = fixedDate
    let encryptedHost = try MetadataSyncCodec.encrypt(
        host: host,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 3,
        modifiedByDeviceID: metadataDevice,
        nonce: Data(repeating: 0x52, count: 12)
    )
    let decryptedHostRecord = try MetadataSyncCodec.decrypt(
        encryptedHost,
        ownerUID: metadataOwner,
        masterKey: masterKey
    )
    if case .host(let decodedHost) = decryptedHostRecord {
        check(decodedHost.id == host.id, "decrypted host metadata preserves its UUID")
        check(decodedHost.hostname == host.hostname, "decrypted host metadata preserves the hostname")
        check(decodedHost.authenticationMethod == .privateKey, "private-key requirement survives metadata sync")
        check(decodedHost.privateKeyPath.isEmpty, "private-key filesystem path is excluded from metadata sync")
        check(decodedHost.groupID == group.id, "decrypted host metadata preserves its group assignment")
    } else {
        check(false, "encrypted host metadata decrypts as a host")
    }
    let encryptedHostJSON = String(decoding: try JSONEncoder().encode(encryptedHost), as: UTF8.self)
    check(!encryptedHostJSON.contains(host.hostname), "Firestore-ready host record does not expose hostname plaintext")
    check(!encryptedHostJSON.contains(host.privateKeyPath), "Firestore-ready host record does not expose private-key path")

    let tombstone = try MetadataSyncCodec.tombstone(
        recordID: host.id,
        recordType: .host,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 4,
        modifiedAt: fixedDate,
        modifiedByDeviceID: metadataDevice,
        nonce: Data(repeating: 0x53, count: 12)
    )
    checkThrowing("encrypted metadata tombstone round trips without plaintext") {
        try MetadataSyncCodec.decrypt(
            tombstone,
            ownerUID: metadataOwner,
            masterKey: masterKey
        ) == .tombstone(recordID: host.id, recordType: .host)
    }

    var oversizedHost = host
    oversizedHost.notes = String(repeating: "x", count: 16_385)
    checkMetadataThrows(.invalidPayload, "oversized host notes are rejected before encryption") {
        _ = try MetadataSyncCodec.encrypt(
            host: oversizedHost,
            ownerUID: metadataOwner,
            masterKey: masterKey,
            revision: 5,
            modifiedByDeviceID: metadataDevice
        )
    }
    checkMetadataThrows(.unsupportedRecordType, "password records cannot enter the metadata codec") {
        _ = try MetadataSyncCodec.tombstone(
            recordID: UUID(),
            recordType: .password,
            ownerUID: metadataOwner,
            masterKey: masterKey,
            revision: 1,
            modifiedAt: fixedDate,
            modifiedByDeviceID: metadataDevice
        )
    }

    let metadataBackend = FirestoreMetadataBackend(
        projectID: "demo-myterm",
        apiRoot: URL(string: "http://127.0.0.1:8080/v1")!
    )
    let metadataToken = "metadata-firebase-id-token"
    let metadataRequest = try metadataBackend.upsertRequest(
        encryptedHost,
        ownerUID: metadataOwner,
        idToken: metadataToken
    )
    check(metadataRequest.httpMethod == "PATCH", "Firestore metadata upsert uses PATCH")
    check(
        metadataRequest.url?.path.hasSuffix("/users/\(metadataOwner)/vault/\(host.id.uuidString.lowercased())") == true,
        "Firestore metadata record path is scoped to UID and random record UUID"
    )
    checkThrowing("Firestore metadata request body exposes no host fields") {
        guard let body = metadataRequest.httpBody else { return false }
        let text = String(decoding: body, as: UTF8.self)
        return !text.contains(host.hostname)
            && !text.contains(host.username)
            && !text.contains(host.notes)
            && !text.contains(host.privateKeyPath)
    }
    let listRequest = try metadataBackend.listRequest(
        ownerUID: metadataOwner,
        idToken: metadataToken,
        pageToken: "next-page-token"
    )
    let listComponents = URLComponents(url: listRequest.url!, resolvingAgainstBaseURL: false)
    check(listRequest.httpMethod == "GET", "Firestore metadata list uses GET")
    check(
        listComponents?.queryItems?.contains(URLQueryItem(name: "pageSize", value: "100")) == true,
        "Firestore metadata list uses a bounded page size"
    )
    check(
        listComponents?.queryItems?.contains(URLQueryItem(name: "pageToken", value: "next-page-token")) == true,
        "Firestore metadata list preserves the opaque page token"
    )
    let createRequest = try metadataBackend.createRequest(
        encryptedHost,
        ownerUID: metadataOwner,
        idToken: metadataToken
    )
    let createComponents = URLComponents(url: createRequest.url!, resolvingAgainstBaseURL: false)
    check(
        createComponents?.queryItems?.contains(URLQueryItem(name: "currentDocument.exists", value: "false")) == true,
        "empty-cloud initialization uses a create-only Firestore precondition"
    )
    check(createRequest.httpMethod == "PATCH", "create-only Firestore metadata preserves the validated PATCH body")

    guard let metadataBody = metadataRequest.httpBody,
          var responseObject = try JSONSerialization.jsonObject(with: metadataBody) as? [String: Any] else {
        throw FirestoreMetadataBackendError.invalidResponse
    }
    responseObject["name"] = "projects/demo-myterm/databases/(default)/documents/users/\(metadataOwner)/vault/\(host.id.uuidString.lowercased())"
    responseObject["updateTime"] = "2026-08-08T05:04:00.000Z"
    let responseData = try JSONSerialization.data(withJSONObject: responseObject)
    checkThrowing("Firestore metadata document decodes to the same encrypted record") {
        try metadataBackend.decodeRecord(responseData) == encryptedHost
    }
    let pageData = try JSONSerialization.data(withJSONObject: [
        "documents": [responseObject],
        "nextPageToken": "opaque-next"
    ])
    checkThrowing("Firestore metadata page decodes records and pagination cursor") {
        let page = try metadataBackend.decodePage(pageData)
        return page.records == [encryptedHost] && page.nextPageToken == "opaque-next"
    }
    checkThrowing("Firestore metadata page preserves authoritative document update time") {
        let page = try metadataBackend.decodePageSnapshot(pageData)
        let expected = ISO8601DateFormatter().date(from: "2026-08-08T05:04:00Z")
        return page.updateTimes[host.id] == expected
    }
    let serverClock = ISO8601DateFormatter().date(from: "2026-08-08T05:08:00Z")!
    let recentCloudUpdate = ISO8601DateFormatter().date(from: "2026-08-08T05:04:00Z")!
    let oldCloudUpdate = ISO8601DateFormatter().date(from: "2026-08-08T04:58:00Z")!
    check(
        RecentCloudUpdatePolicy.requiresConfirmation(updateTime: recentCloudUpdate, serverDate: serverClock),
        "cloud update within five minutes requires user confirmation"
    )
    check(
        !RecentCloudUpdatePolicy.requiresConfirmation(updateTime: oldCloudUpdate, serverDate: serverClock),
        "cloud update older than five minutes can use automatic last-writer-wins"
    )
    check(
        RecentCloudUpdatePolicy.requiresConfirmation(updateTime: nil, serverDate: serverClock),
        "missing authoritative update time fails safely into confirmation"
    )

    let invalidEmptyRecord = EncryptedSyncRecord(
        id: host.id,
        recordType: .host,
        ciphertext: Data(),
        nonce: encryptedHost.nonce,
        authenticationTag: encryptedHost.authenticationTag,
        keyVersion: encryptedHost.keyVersion,
        formatVersion: encryptedHost.formatVersion,
        revision: encryptedHost.revision,
        modifiedAt: encryptedHost.modifiedAt,
        modifiedByDeviceID: encryptedHost.modifiedByDeviceID,
        deleted: false
    )
    checkFirestoreMetadataThrows(.invalidRecord, "non-deleted Firestore record cannot use empty ciphertext") {
        _ = try metadataBackend.upsertRequest(
            invalidEmptyRecord,
            ownerUID: metadataOwner,
            idToken: metadataToken
        )
    }

    let emptyCloudPreview = try MetadataSyncPreviewPlanner.makePreview(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: [],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(emptyCloudPreview.uploadCount == 2, "first sync preview proposes local groups and hosts for upload when cloud is empty")
    check(emptyCloudPreview.downloadCount == 0, "empty cloud preview does not propose downloads")
    check(emptyCloudPreview.conflictCount == 0, "empty cloud preview has no conflicts")

    let matchingPreview = try MetadataSyncPreviewPlanner.makePreview(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: [encryptedGroup, encryptedHost],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(matchingPreview.unchangedCount == 2, "preview ignores the local-only private-key path when comparing devices")
    check(matchingPreview.conflictCount == 0, "matching encrypted metadata has no false conflicts")

    let downloadPreview = try MetadataSyncPreviewPlanner.makePreview(
        localGroups: [],
        localHosts: [],
        remoteRecords: [encryptedGroup, encryptedHost],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(downloadPreview.downloadCount == 2, "first sync preview proposes cloud-only records for download")

    var changedHost = host
    changedHost.notes = "Changed only in Firebase."
    let encryptedChangedHost = try MetadataSyncCodec.encrypt(
        host: changedHost,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 4,
        modifiedByDeviceID: metadataDevice,
        nonce: Data(repeating: 0x54, count: 12)
    )
    let conflictPreview = try MetadataSyncPreviewPlanner.makePreview(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: [encryptedGroup, encryptedChangedHost],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(conflictPreview.conflictCount == 1, "different content with the same UUID is reported as a conflict")
    check(conflictPreview.uploadCount == 0 && conflictPreview.downloadCount == 0, "conflicts never guess an overwrite direction")

    let tombstonePreview = try MetadataSyncPreviewPlanner.makePreview(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: [encryptedGroup, tombstone],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(tombstonePreview.conflictCount == 1, "a cloud tombstone never silently deletes a present local host")

    let unknownTombstone = try MetadataSyncCodec.tombstone(
        recordID: UUID(uuidString: "70000000-0000-0000-0000-000000000099")!,
        recordType: .host,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 2,
        modifiedAt: fixedDate,
        modifiedByDeviceID: metadataDevice,
        nonce: Data(repeating: 0x55, count: 12)
    )
    let noActionTombstonePreview = try MetadataSyncPreviewPlanner.makePreview(
        localGroups: [],
        localHosts: [],
        remoteRecords: [unknownTombstone],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(noActionTombstonePreview.remoteTombstoneCount == 1, "a cloud-only tombstone is shown as requiring no local action")

    let orphanGroup = HostGroup(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000088")!,
        name: "Orphan",
        parentID: UUID(uuidString: "70000000-0000-0000-0000-000000000077")!,
        createdAt: fixedDate
    )
    let encryptedOrphan = try MetadataSyncCodec.encrypt(
        group: orphanGroup,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 1,
        modifiedByDeviceID: metadataDevice,
        nonce: Data(repeating: 0x56, count: 12)
    )
    checkMetadataPreviewThrows(.invalidRemoteHierarchy, "preview rejects a remote group whose parent is missing") {
        _ = try MetadataSyncPreviewPlanner.makePreview(
            localGroups: [],
            localHosts: [],
            remoteRecords: [encryptedOrphan],
            ownerUID: metadataOwner,
            masterKey: masterKey
        )
    }

    checkMetadataPreviewThrows(.duplicateRemoteIdentity, "preview rejects duplicate encrypted record identities") {
        _ = try MetadataSyncPreviewPlanner.makePreview(
            localGroups: [],
            localHosts: [],
            remoteRecords: [encryptedGroup, encryptedGroup],
            ownerUID: metadataOwner,
            masterKey: masterKey
        )
    }

    let deviceDirectory = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-device-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    let deviceFile = deviceDirectory.appending(path: "device-id")
    defer { try? FileManager.default.removeItem(at: deviceDirectory) }
    let identityStore = SyncDeviceIdentityStore(fileURL: deviceFile)
    let firstDeviceID = try identityStore.loadOrCreate()
    let secondDeviceID = try identityStore.loadOrCreate()
    check(firstDeviceID == secondDeviceID, "sync device identifier remains stable on the same Mac")
    let devicePermissions = try FileManager.default.attributesOfItem(atPath: deviceFile.path)[.posixPermissions] as? NSNumber
    check(devicePermissions?.intValue == 0o600, "sync device identifier uses owner-only permissions")
    let deviceText = String(decoding: try Data(contentsOf: deviceFile), as: UTF8.self)
    check(!deviceText.contains(host.hostname) && !deviceText.contains(host.username), "sync device identifier contains no host fields")

    let initialUploadRecords = try MetadataSyncInitialUploadPlanner.makeRecords(
        groups: [group],
        hosts: [host],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        deviceID: firstDeviceID
    )
    check(initialUploadRecords.count == 2, "empty-cloud initialization prepares every local group and host")
    check(initialUploadRecords.allSatisfy { $0.revision == 1 }, "empty-cloud initialization starts every record at revision one")
    check(initialUploadRecords.allSatisfy { $0.modifiedByDeviceID == firstDeviceID }, "initial encrypted records use the stable device identifier")
    check(initialUploadRecords.first?.recordType == .group && initialUploadRecords.last?.recordType == .host, "initial upload orders groups before hosts")
    if let uploadedHostRecord = initialUploadRecords.first(where: { $0.recordType == .host }),
       case .host(let uploadedHost) = try MetadataSyncCodec.decrypt(
        uploadedHostRecord,
        ownerUID: metadataOwner,
        masterKey: masterKey
       ) {
        check(uploadedHost.privateKeyPath.isEmpty, "initial cloud upload excludes the local private-key path")
    } else {
        check(false, "initial cloud upload host record decrypts for verification")
    }

    let hostDigest = try MetadataSyncCodec.contentDigest(host: host)
    var hostWithDifferentLocalKey = host
    hostWithDifferentLocalKey.privateKeyPath = "/Users/another-mac/.ssh/a-different-key"
    checkThrowing("metadata baseline digest excludes the device-local private-key path") {
        try MetadataSyncCodec.contentDigest(host: hostWithDifferentLocalKey) == hostDigest
    }
    let baseline = try MetadataSyncBaselinePlanner.makeBaseline(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: initialUploadRecords,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        deviceID: firstDeviceID,
        createdAt: fixedDate
    )
    check(baseline.entries.count == 2, "matching local and cloud records produce a complete sync baseline")
    check(baseline.entries.allSatisfy { $0.remoteRevision == 1 }, "sync baseline records the verified remote revision")
    let baselineText = String(decoding: try JSONEncoder().encode(baseline), as: UTF8.self)
    check(!baselineText.contains(host.hostname) && !baselineText.contains(host.username), "sync baseline contains no host plaintext")
    check(!baselineText.contains(metadataOwner), "sync baseline stores a Firebase UID digest instead of the raw UID")

    let baselineDirectory = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-baseline-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: baselineDirectory) }
    let baselineStore = MetadataSyncBaselineStore(directoryURL: baselineDirectory)
    let baselineURL = try baselineStore.save(baseline, ownerUID: metadataOwner)
    checkThrowing("sync baseline survives an owner-scoped local round trip") {
        try baselineStore.load(ownerUID: metadataOwner) == baseline
    }
    let baselinePermissions = try FileManager.default.attributesOfItem(atPath: baselineURL.path)[.posixPermissions] as? NSNumber
    check(baselinePermissions?.intValue == 0o600, "sync baseline uses owner-only file permissions")

    let matchingManualPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: initialUploadRecords,
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(matchingManualPlan.unchangedCount == 2, "manual sync plan recognizes records matching the baseline")
    check(!matchingManualPlan.canApplyLocalChanges, "manual sync does not write when nothing changed")

    var timestampOnlyChangedHost = host
    timestampOnlyChangedHost.updatedAt = fixedDate.addingTimeInterval(30)
    let timestampOnlyPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [timestampOnlyChangedHost],
        remoteRecords: initialUploadRecords,
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(timestampOnlyPlan.uploadCount == 1 && timestampOnlyPlan.conflictCount == 0, "a restored device baseline turns a save-time timestamp change into a local upload instead of a conflict")

    var manualChangedHost = host
    manualChangedHost.notes = "Changed only on this Mac."
    manualChangedHost.updatedAt = fixedDate.addingTimeInterval(60)
    let localOnlyPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [manualChangedHost],
        remoteRecords: initialUploadRecords,
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(localOnlyPlan.uploadCount == 1, "manual sync identifies a local-only host edit for upload")
    check(localOnlyPlan.canApplyLocalChanges, "local-only changes are eligible for guarded manual upload")
    check(localOnlyPlan.preview.conflictCount == 0 && localOnlyPlan.preview.uploadCount == 1, "baseline-aware preview no longer mislabels a local-only edit as conflict")

    let completedManualUpload = try MetadataSyncCodec.encrypt(
        host: manualChangedHost,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 2,
        modifiedByDeviceID: firstDeviceID,
        nonce: Data(repeating: 0x58, count: 12)
    )
    let repairPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [manualChangedHost],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [completedManualUpload],
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(repairPlan.repairCount == 1, "a verified upload from this device can repair an interrupted local baseline write")
    check(repairPlan.canApplyLocalChanges, "baseline repair is safe without another cloud upload")

    var otherDeviceChangedHost = host
    otherDeviceChangedHost.notes = "Changed only on another Mac."
    otherDeviceChangedHost.updatedAt = fixedDate.addingTimeInterval(120)
    let otherDeviceUpload = try MetadataSyncCodec.encrypt(
        host: otherDeviceChangedHost,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 2,
        modifiedByDeviceID: UUID(uuidString: "70000000-8000-9000-a000-b00000000099")!,
        nonce: Data(repeating: 0x59, count: 12)
    )
    let simultaneousPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [manualChangedHost],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [otherDeviceUpload],
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(simultaneousPlan.conflictCount == 1, "a simultaneous edit from another device never auto-overwrites")
    check(!simultaneousPlan.canApplyLocalChanges, "conflicts block every guarded manual upload")

    let remoteOnlyPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [otherDeviceUpload],
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(remoteOnlyPlan.downloadCount == 1, "a remote-only edit is offered for a future download instead of upload")
    check(!remoteOnlyPlan.canApplyLocalChanges, "remote changes block local upload until merge support is available")
    check(remoteOnlyPlan.canApplyRemoteChanges, "a remote-only edit is eligible for guarded download")

    let downloadedMerge = try MetadataManualDownloadPlanner.makeResult(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [otherDeviceUpload],
        baseline: baseline,
        plan: remoteOnlyPlan,
        ownerUID: metadataOwner,
        masterKey: masterKey
    )
    check(downloadedMerge.downloadedCount == 1, "guarded download applies exactly the remote-only record")
    check(downloadedMerge.document.hosts.first?.notes == otherDeviceChangedHost.notes, "guarded download uses the verified cloud metadata")
    check(downloadedMerge.document.hosts.first?.privateKeyPath == host.privateKeyPath, "guarded download preserves the device-local private-key path")
    check(downloadedMerge.baseline.entries.first(where: { $0.recordID == host.id })?.remoteRevision == 2, "guarded download advances the local baseline to the verified cloud revision")
    try MetadataMergedInventoryValidator.validate(downloadedMerge.document)

    let convergedPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: downloadedMerge.document.groups,
        localHosts: downloadedMerge.document.hosts,
        remoteRecords: downloadedMerge.remoteRecords,
        baseline: downloadedMerge.baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(convergedPlan.unchangedCount == 2 && convergedPlan.conflictCount == 0, "downloaded merge converges to the cloud without a false conflict")

    let movedTargetGroup = HostGroup(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000004")!,
        name: "Datacenter",
        parentID: nil,
        createdAt: fixedDate
    )
    let groupMoveInitialRecords = try MetadataSyncInitialUploadPlanner.makeRecords(
        groups: [group, movedTargetGroup],
        hosts: [host],
        ownerUID: metadataOwner,
        masterKey: masterKey,
        deviceID: firstDeviceID
    )
    let secondMetadataDeviceID = UUID(uuidString: "70000000-8000-9000-a000-b00000000055")!
    let groupMoveBaselineA = try MetadataSyncBaselinePlanner.makeBaseline(
        localGroups: [group, movedTargetGroup],
        localHosts: [host],
        remoteRecords: groupMoveInitialRecords,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        deviceID: firstDeviceID,
        createdAt: fixedDate
    )
    let groupMoveBaselineB = try MetadataSyncBaselinePlanner.makeBaseline(
        localGroups: [group, movedTargetGroup],
        localHosts: [host],
        remoteRecords: groupMoveInitialRecords,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        deviceID: secondMetadataDeviceID,
        createdAt: fixedDate
    )
    var hostMovedOnDeviceA = host
    hostMovedOnDeviceA.groupID = movedTargetGroup.id
    hostMovedOnDeviceA.updatedAt = fixedDate.addingTimeInterval(180)
    let deviceAGroupMovePlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group, movedTargetGroup],
        localHosts: [hostMovedOnDeviceA],
        remoteRecords: groupMoveInitialRecords,
        baseline: groupMoveBaselineA,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate.addingTimeInterval(180)
    )
    check(deviceAGroupMovePlan.uploadCount == 1 && deviceAGroupMovePlan.conflictCount == 0, "device A group move produces one guarded host upload")

    let movedHostCloudRecord = try MetadataSyncCodec.encrypt(
        host: hostMovedOnDeviceA,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 2,
        modifiedByDeviceID: firstDeviceID,
        nonce: Data(repeating: 0x5B, count: 12)
    )
    let groupMoveRemoteRecords = groupMoveInitialRecords.filter { $0.recordType == .group } + [movedHostCloudRecord]
    let deviceBGroupMovePlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group, movedTargetGroup],
        localHosts: [host],
        remoteRecords: groupMoveRemoteRecords,
        baseline: groupMoveBaselineB,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate.addingTimeInterval(181)
    )
    check(deviceBGroupMovePlan.downloadCount == 1 && deviceBGroupMovePlan.conflictCount == 0, "device B recognizes device A group move as one safe download")

    let deviceBGroupMoveMerge = try MetadataManualDownloadPlanner.makeResult(
        localGroups: [group, movedTargetGroup],
        localHosts: [host],
        remoteRecords: groupMoveRemoteRecords,
        baseline: groupMoveBaselineB,
        plan: deviceBGroupMovePlan,
        ownerUID: metadataOwner,
        masterKey: masterKey
    )
    check(deviceBGroupMoveMerge.document.hosts.count == 1, "device B group move merge does not duplicate the host")
    check(deviceBGroupMoveMerge.document.hosts.first?.id == host.id, "device B group move merge preserves the host identity")
    check(deviceBGroupMoveMerge.document.hosts.first?.groupID == movedTargetGroup.id, "device B applies the group selected on device A")
    check(deviceBGroupMoveMerge.document.hosts.first?.privateKeyPath == host.privateKeyPath, "device B group move merge preserves its device-local private-key path")
    check(deviceBGroupMoveMerge.document.groups.count == 2, "device B group move merge does not duplicate groups")
    let deviceBGroupMoveConvergedPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: deviceBGroupMoveMerge.document.groups,
        localHosts: deviceBGroupMoveMerge.document.hosts,
        remoteRecords: deviceBGroupMoveMerge.remoteRecords,
        baseline: deviceBGroupMoveMerge.baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate.addingTimeInterval(182)
    )
    check(deviceBGroupMoveConvergedPlan.unchangedCount == 3 && deviceBGroupMoveConvergedPlan.conflictCount == 0, "both devices converge after syncing a host group move")

    let remoteDeletion = try MetadataSyncCodec.tombstone(
        recordID: host.id,
        recordType: .host,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        revision: 2,
        modifiedAt: fixedDate.addingTimeInterval(120),
        modifiedByDeviceID: UUID(uuidString: "70000000-8000-9000-a000-b00000000099")!,
        nonce: Data(repeating: 0x5A, count: 12)
    )
    let remoteDeletionPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [host],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [remoteDeletion],
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(remoteDeletionPlan.deletionCount == 1 && remoteDeletionPlan.conflictCount == 0, "a remote tombstone is recognized as a safe remote-only deletion")
    check(remoteDeletionPlan.preview.downloadCount == 1, "a safe remote tombstone is presented as a cloud download action")

    let localDeletionPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [],
        remoteRecords: initialUploadRecords,
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(localDeletionPlan.deletionCount == 1 && localDeletionPlan.conflictCount == 0, "a local-only deletion is recognized for encrypted tombstone upload")
    check(localDeletionPlan.preview.uploadCount == 1, "a safe local deletion is presented as an upload action")

    let localDeletionAfterRemoteEditPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [otherDeviceUpload],
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(localDeletionAfterRemoteEditPlan.conflictCount == 1, "a local deletion racing a remote edit still uses conflict confirmation")

    let localEditAfterRemoteDeletionPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [manualChangedHost],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [remoteDeletion],
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(localEditAfterRemoteDeletionPlan.conflictCount == 1, "a local edit racing a remote deletion still uses conflict confirmation")

    let retiredBaseline = MetadataSyncBaselinePlanner.removingEntry(recordID: host.id, from: baseline)
    let retiredPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [],
        remoteRecords: initialUploadRecords.filter { $0.recordType == .group } + [remoteDeletion],
        baseline: retiredBaseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(retiredPlan.unchangedCount == 1 && retiredPlan.deletionCount == 0 && retiredPlan.conflictCount == 0, "a completed cloud tombstone stays retired without recurring conflicts")

    var newHost = host
    newHost.id = UUID(uuidString: "70000000-0000-0000-0000-000000000003")!
    newHost.name = "New Local Host"
    let newRecordPlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: [group],
        localHosts: [host, newHost],
        remoteRecords: initialUploadRecords,
        baseline: baseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(newRecordPlan.uploadCount == 1 && newRecordPlan.canApplyLocalChanges, "a new local UUID uses guarded create-only upload")

    let restoredInventory = try MetadataSyncCloudRestorePlanner.makeInventory(
        remoteRecords: initialUploadRecords,
        ownerUID: metadataOwner,
        masterKey: masterKey
    )
    check(restoredInventory.groups == [group], "empty local inventory restores the encrypted cloud group")
    check(restoredInventory.hosts.count == 1 && restoredInventory.hosts[0].id == host.id, "empty local inventory restores the encrypted cloud host")
    check(restoredInventory.hosts[0].privateKeyPath.isEmpty, "cloud restore never invents or restores a private-key path")
    let restoredDeviceBaseline = try MetadataSyncBaselinePlanner.makeBaseline(
        localGroups: restoredInventory.groups,
        localHosts: restoredInventory.hosts,
        remoteRecords: initialUploadRecords,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        deviceID: UUID(uuidString: "70000000-8000-9000-a000-b00000000077")!,
        createdAt: fixedDate
    )
    let restoredDevicePlan = try MetadataManualSyncPlanner.makePlan(
        localGroups: restoredInventory.groups,
        localHosts: restoredInventory.hosts,
        remoteRecords: initialUploadRecords,
        baseline: restoredDeviceBaseline,
        ownerUID: metadataOwner,
        masterKey: masterKey,
        generatedAt: fixedDate
    )
    check(restoredDevicePlan.unchangedCount == 2 && restoredDevicePlan.conflictCount == 0, "blank-device restore can establish a complete baseline immediately")

    let restoredWithOldTombstone = try MetadataSyncCloudRestorePlanner.makeInventory(
        remoteRecords: initialUploadRecords + [unknownTombstone],
        ownerUID: metadataOwner,
        masterKey: masterKey
    )
    check(restoredWithOldTombstone.hosts.count == 1, "empty local restore safely ignores cloud-only tombstones")

    var unsafeRestoredHost = restoredInventory.hosts[0]
    unsafeRestoredHost.privateKeyPath = "/unexpected/cloud/path"
    checkCloudRestoreThrows(.invalidInventory, "cloud restore rejects any private-key filesystem path") {
        try CloudInventoryRestoreValidator.validate(
            InventoryDocument(groups: restoredInventory.groups, hosts: [unsafeRestoredHost])
        )
    }

    let duplicateGroup = HostGroup(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000066")!,
        name: group.name.lowercased(),
        parentID: group.parentID,
        createdAt: fixedDate
    )
    checkCloudRestoreThrows(.invalidInventory, "cloud restore rejects duplicate group names at the same level") {
        try CloudInventoryRestoreValidator.validate(
            InventoryDocument(groups: [group, duplicateGroup], hosts: [])
        )
    }

    let cycleAID = UUID(uuidString: "70000000-0000-0000-0000-000000000061")!
    let cycleBID = UUID(uuidString: "70000000-0000-0000-0000-000000000062")!
    let cycleA = HostGroup(id: cycleAID, name: "Cycle A", parentID: cycleBID, createdAt: fixedDate)
    let cycleB = HostGroup(id: cycleBID, name: "Cycle B", parentID: cycleAID, createdAt: fixedDate)
    checkCloudRestoreThrows(.invalidInventory, "cloud restore rejects cyclic group ancestry before persistence") {
        try CloudInventoryRestoreValidator.validate(
            InventoryDocument(groups: [cycleA, cycleB], hosts: [])
        )
    }
} catch {
    check(false, "encrypted host and group metadata suite: \(error)")
}

do {
    let passwordMasterKey = try VaultMasterKey(rawRepresentation: Data(0..<32), version: 1)
    let hostID = UUID(uuidString: "81000000-2000-3000-4000-500000000001")!
    let passwordRecordID = PasswordSyncCodec.recordID(for: hostID)
    check(passwordRecordID == PasswordSyncCodec.recordID(for: hostID), "password record UUID is deterministic for a host")
    check(
        PasswordSyncConflictResolution.preferRemote.downloadsRemoteConflict,
        "new-device password recovery resolves conflicts by downloading the cloud copy"
    )
    check(
        !PasswordSyncConflictResolution.preferLocal.downloadsRemoteConflict,
        "normal password sync keeps last-writer conflict handling"
    )
    check(passwordRecordID != hostID, "password record UUID does not expose the host UUID directly")

    let passwordData = Data("Case-Sensitive 密碼 !@#$%^&*()".utf8)
    let passwordRecord = try PasswordSyncCodec.encrypt(
        passwordData: passwordData,
        hostID: hostID,
        ownerUID: ownerUID,
        masterKey: passwordMasterKey,
        revision: 1,
        modifiedByDeviceID: deviceID,
        modifiedAt: fixedDate,
        nonce: Data([0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb])
    )
    let decryptedPassword = try PasswordSyncCodec.decrypt(
        passwordRecord,
        ownerUID: ownerUID,
        masterKey: passwordMasterKey
    )
    check(decryptedPassword.hostID == hostID && decryptedPassword.passwordData == passwordData,
          "password record decrypts to the exact UTF-8 Keychain bytes")
    check(passwordRecord.ciphertext.range(of: passwordData) == nil,
          "encrypted password record contains no plaintext password bytes")
    checkThrowing("Firestore accepts a structurally valid encrypted password record") {
        let request = try FirestoreMetadataBackend(projectID: "demo-myterm").upsertRequest(
            passwordRecord,
            ownerUID: ownerUID,
            idToken: "test-token"
        )
        return request.httpMethod == "PATCH" && request.httpBody?.range(of: passwordData) == nil
    }
    checkThrows(.authenticationFailed, "password record AAD rejects a different Firebase UID") {
        _ = try PasswordSyncCodec.decrypt(
            passwordRecord,
            ownerUID: "different-user",
            masterKey: passwordMasterKey
        )
    }
    let passwordTombstone = try PasswordSyncCodec.tombstone(
        recordID: passwordRecordID,
        ownerUID: ownerUID,
        masterKey: passwordMasterKey,
        revision: 2,
        modifiedByDeviceID: deviceID,
        modifiedAt: fixedDate
    )
    check(passwordTombstone.deleted && passwordTombstone.ciphertext.isEmpty,
          "retired password becomes an authenticated empty tombstone")
    checkThrowing("password tombstone authenticates without containing secret bytes") {
        try PasswordSyncCodec.validateTombstone(
            passwordTombstone,
            ownerUID: ownerUID,
            masterKey: passwordMasterKey
        )
        return passwordTombstone.ciphertext.range(of: passwordData) == nil
    }

    let temporaryBaselineDirectory = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-password-baseline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryBaselineDirectory) }
    let baselineStore = PasswordSyncBaselineStore(directoryURL: temporaryBaselineDirectory)
    let baseline = PasswordSyncBaseline(
        schemaVersion: PasswordSyncBaseline.schemaVersion,
        ownerUIDDigest: MetadataSyncBaselineStore.ownerDigest(ownerUID),
        deviceID: deviceID,
        entries: [PasswordSyncBaselineEntry(
            recordID: passwordRecordID,
            hostID: hostID,
            remoteRevision: 1,
            localSecretDigest: try PasswordSyncCodec.contentDigest(
                passwordData: passwordData,
                hostID: hostID,
                masterKey: passwordMasterKey
            ),
            remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(passwordRecord)
        )]
    )
    try baselineStore.save(baseline, ownerUID: ownerUID)
    checkThrowing("password sync baseline round-trips with keyed digests") {
        try baselineStore.load(ownerUID: ownerUID) == baseline
    }
    let baselineFiles = try FileManager.default.contentsOfDirectory(
        at: temporaryBaselineDirectory,
        includingPropertiesForKeys: nil
    )
    let baselineBytes = try Data(contentsOf: baselineFiles[0])
    check(baselineBytes.range(of: passwordData) == nil,
          "password sync baseline never stores plaintext password bytes")
} catch {
    check(false, "encrypted password sync suite: \(error)")
}

do {
    let ownerUID = "audit-owner"
    let masterKey = try VaultMasterKey.generate()
    let sourceDeviceID = UUID()
    let recordID = UUID()
    let sessionID = UUID()
    let hostID = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let endedAt = startedAt.addingTimeInterval(42)
    var record = ConnectionAuditRecord(
        id: recordID,
        sessionID: sessionID,
        hostID: hostID,
        hostName: "Encrypted Audit Host",
        hostname: "192.0.2.55",
        port: 22,
        username: "audit-user",
        sourceDeviceID: sourceDeviceID,
        sourceDeviceName: "Audit Test Mac",
        platform: .ubuntu,
        startedAt: startedAt
    )
    record.connectedAt = startedAt.addingTimeInterval(2)
    record.endedAt = endedAt
    record.status = .completed
    record.exitCode = 0

    let encrypted = try ConnectionAuditSyncCodec.encrypt(
        record,
        ownerUID: ownerUID,
        masterKey: masterKey
    )
    checkThrowing("connection audit payload survives end-to-end encryption") {
        try ConnectionAuditSyncCodec.decrypt(
            encrypted,
            ownerUID: ownerUID,
            masterKey: masterKey
        ) == record
    }
    let encryptedJSON = String(decoding: try JSONEncoder().encode(encrypted), as: UTF8.self)
    check(
        !encryptedJSON.contains(record.hostName) &&
            !encryptedJSON.contains(record.hostname) &&
            !encryptedJSON.contains(record.username) &&
            !encryptedJSON.contains(record.sourceDeviceName!),
        "connection audit cloud record exposes no host, account, address, or device-name plaintext"
    )

    var ongoing = record
    ongoing.status = .connected
    ongoing.endedAt = nil
    do {
        _ = try ConnectionAuditSyncCodec.encrypt(
            ongoing,
            ownerUID: ownerUID,
            masterKey: masterKey
        )
        check(false, "ongoing connection audit is never eligible for cloud encryption")
    } catch let error as ConnectionAuditSyncCodecError {
        check(error == .invalidRecord, "ongoing connection audit is never eligible for cloud encryption")
    }

    let backend = FirestoreConnectionAuditBackend(projectID: "demo-myterm")
    let createRequest = try backend.createRequest(
        encrypted,
        ownerUID: ownerUID,
        idToken: "id-token"
    )
    check(
        createRequest.httpMethod == "PATCH" &&
            createRequest.url?.absoluteString.contains("/users/audit-owner/connectionLogs/") == true &&
            createRequest.url?.absoluteString.contains("currentDocument.exists=false") == true,
        "connection audit backend uses an owner-scoped create-only document"
    )
    let requestBody = String(decoding: createRequest.httpBody ?? Data(), as: UTF8.self)
    check(
        !requestBody.contains(record.hostName) &&
            !requestBody.contains(record.hostname) &&
            !requestBody.contains(record.username) &&
            !requestBody.contains(record.sourceDeviceName!),
        "connection audit Firestore request contains only ciphertext metadata"
    )
    let listRequest = try backend.listRequest(
        ownerUID: ownerUID,
        idToken: "id-token",
        pageToken: "opaque-token"
    )
    check(
        listRequest.httpMethod == "GET" &&
            listRequest.url?.absoluteString.contains("pageSize=100") == true &&
            listRequest.url?.absoluteString.contains("pageToken=opaque-token") == true,
        "connection audit backend uses bounded pagination"
    )

    var responseObject = try JSONSerialization.jsonObject(
        with: createRequest.httpBody ?? Data()
    ) as! [String: Any]
    responseObject["name"] = "projects/demo-myterm/databases/(default)/documents/users/\(ownerUID)/connectionLogs/\(recordID.uuidString.lowercased())"
    let responseData = try JSONSerialization.data(withJSONObject: responseObject)
    checkThrowing("connection audit Firestore document decodes to the same encrypted record") {
        try backend.decodeRecord(responseData) == encrypted
    }
} catch {
    check(false, "encrypted connection audit sync suite: \(error)")
}

LocalSecretVaultStore.resetForTesting()
print("\n\(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
}
}
