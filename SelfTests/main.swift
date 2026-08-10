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

private func baseHost() -> HostProfile {
    var host = HostProfile()
    host.name = "Test"
    host.hostname = "192.0.2.10"
    host.username = "operator"
    return host
}

let initializationPacket = SFTPProtocolCodec.initializationPacket()
check(initializationPacket == Data([0, 0, 0, 5, 1, 0, 0, 0, 3]),
      "SFTP v3 initialization packet is framed correctly")

do {
    var payload = SFTPPacketWriter()
    payload.append(SFTPPacketType.name)
    payload.append(UInt32(42))
    payload.append(UInt32(1))
    payload.append(string: "example.txt")
    payload.append(string: "-rw-r--r-- example.txt")
    payload.append(UInt32(0x0000_000D)) // size, permissions, timestamps
    payload.append(UInt64(12_345))
    payload.append(UInt32(0o100644))
    payload.append(UInt32(1_700_000_000))
    payload.append(UInt32(1_700_000_100))
    let framed = payload.framed()
    let packet = framed.dropFirst(4)
    var (type, reader) = try SFTPProtocolCodec.responseReader(Data(packet), expectedRequestID: 42)
    check(type == SFTPPacketType.name, "SFTP response type is decoded")
    let entries = try SFTPProtocolCodec.parseNameEntries(&reader)
    check(entries.count == 1 && entries[0].name == "example.txt",
          "SFTP directory name is decoded")
    check(entries[0].attributes.size == 12_345 && entries[0].attributes.kind == .regularFile,
          "SFTP v3 attributes and POSIX file type are decoded")
} catch {
    check(false, "SFTP directory packet round trip: \(error)")
}

do {
    var reader = SFTPPacketReader(Data([0, 0, 0, 10, 1, 2]))
    _ = try reader.readData()
    check(false, "truncated SFTP strings are rejected")
} catch SFTPProtocolError.malformedPacket {
    check(true, "truncated SFTP strings are rejected")
} catch {
    check(false, "truncated SFTP strings are rejected: \(error)")
}

do {
    let original = SFTPLocalDragPayload(paths: ["/tmp/one.txt", "/tmp/folder"])
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SFTPLocalDragPayload.self, from: encoded)
    check(decoded == original, "SFTP local multi-item drag payload round trips")

    let remote = SFTPRemoteDragPayload(
        sessionID: UUID(),
        sourceDirectory: "/home/tester",
        names: ["one.txt", "folder"]
    )
    let remoteEncoded = try JSONEncoder().encode(remote)
    let remoteDecoded = try JSONDecoder().decode(SFTPRemoteDragPayload.self, from: remoteEncoded)
    check(remoteDecoded == remote,
          "SFTP remote drag payload preserves its session and source directory")
} catch {
    check(false, "SFTP drag payload round trip: \(error)")
}

do {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-SFTP-Integration-\(UUID().uuidString)", directoryHint: .isDirectory)
    let remoteRoot = root.appending(path: "remote", directoryHint: .isDirectory)
    let sourceRoot = root.appending(path: "source", directoryHint: .isDirectory)
    let downloadRoot = root.appending(path: "download", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let client = try SFTPClient.connectForTesting(
        executableURL: URL(fileURLWithPath: "/usr/libexec/sftp-server"),
        arguments: ["-d", remoteRoot.path]
    )
    defer { client.close() }
    let resolvedRoot = try client.realPath(".")
    let canonicalResolvedRoot = URL(fileURLWithPath: resolvedRoot)
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
    let canonicalExpectedRoot = remoteRoot
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
    check(canonicalResolvedRoot == canonicalExpectedRoot,
          "SFTP transport resolves the server start directory")

    let sourceFile = sourceRoot.appending(path: "sample.txt")
    try Data("hello from MyTerm".utf8).write(to: sourceFile)
    var uploadProgress: UInt64 = 0
    try client.uploadItem(at: sourceFile, to: resolvedRoot) { completed, _ in
        uploadProgress = completed
    }
    check(uploadProgress == 17, "SFTP upload reports byte progress")

    var entries = try client.listDirectory(resolvedRoot)
    guard let uploaded = entries.first(where: { $0.name == "sample.txt" }) else {
        throw SFTPProtocolError.malformedPacket
    }
    check(uploaded.attributes.kind == .regularFile, "SFTP upload creates a regular remote file")

    do {
        try client.uploadItem(at: sourceFile, to: resolvedRoot) { _, _ in }
        check(false, "SFTP upload never overwrites an existing target")
    } catch SFTPFileOperationError.destinationExists {
        check(true, "SFTP upload never overwrites an existing target")
    }

    let existingNames = try client.existingItemNames(
        ["sample.txt", "not-present.txt"],
        in: resolvedRoot
    )
    check(existingNames == ["sample.txt"],
          "SFTP overwrite preflight reports only existing targets")

    let replacementData = Data("replacement".utf8)
    try replacementData.write(to: sourceFile)
    try client.uploadItem(at: sourceFile, to: resolvedRoot, overwrite: true) { _, _ in }
    let replacedRemoteData = try Data(contentsOf: remoteRoot.appending(path: "sample.txt"))
    check(replacedRemoteData == replacementData,
          "confirmed SFTP upload replaces an existing remote file")

    let renamedPath = resolvedRoot + "/renamed.txt"
    try client.rename(from: resolvedRoot + "/sample.txt", to: renamedPath)
    try client.setPermissions(0o640, at: renamedPath)
    let remotePermissions = try FileManager.default.attributesOfItem(atPath: remoteRoot.appending(path: "renamed.txt").path)[.posixPermissions] as? NSNumber
    check(remotePermissions?.uint32Value == 0o640, "SFTP permission changes reach the remote filesystem")

    entries = try client.listDirectory(resolvedRoot)
    guard let renamed = entries.first(where: { $0.name == "renamed.txt" }) else {
        throw SFTPProtocolError.malformedPacket
    }
    var downloadProgress: UInt64 = 0
    try client.downloadItem(renamed, from: resolvedRoot, to: downloadRoot) { completed, _ in
        downloadProgress = completed
    }
    let downloadedData = try Data(contentsOf: downloadRoot.appending(path: "renamed.txt"))
    check(downloadedData == replacementData && downloadProgress == UInt64(replacementData.count),
          "SFTP download preserves file bytes and reports progress")

    let downloadedFile = downloadRoot.appending(path: "renamed.txt")
    try Data("stale local copy".utf8).write(to: downloadedFile)
    try client.downloadItem(
        renamed,
        from: resolvedRoot,
        to: downloadRoot,
        overwrite: true
    ) { _, _ in }
    let replacedLocalData = try Data(contentsOf: downloadedFile)
    check(replacedLocalData == replacementData,
          "confirmed SFTP download safely replaces an existing local file")

    let tree = sourceRoot.appending(path: "tree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
    try Data("nested".utf8).write(to: tree.appending(path: "nested.txt"))
    try client.uploadItem(at: tree, to: resolvedRoot) { _, _ in }
    entries = try client.listDirectory(resolvedRoot)
    guard let remoteTree = entries.first(where: { $0.name == "tree" }) else {
        throw SFTPProtocolError.malformedPacket
    }
    let secondDownload = root.appending(path: "download-tree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: secondDownload, withIntermediateDirectories: false)
    try client.downloadItem(remoteTree, from: resolvedRoot, to: secondDownload) { _, _ in }
    let nestedDownloadData = try Data(contentsOf: secondDownload.appending(path: "tree/nested.txt"))
    check(
        nestedDownloadData == Data("nested".utf8),
        "SFTP recursively transfers directories"
    )

    try client.removeRecursively(path: renamedPath, kind: .regularFile)
    try client.removeRecursively(path: resolvedRoot + "/tree", kind: .directory)
    let remainingRemoteEntries = try client.listDirectory(resolvedRoot)
    check(remainingRemoteEntries.isEmpty,
          "SFTP recursive deletion removes only the selected remote targets")
} catch {
    check(false, "SFTP local-server integration: \(error)")
}

do {
    var host = baseHost()
    host.name = "  Production  "
    let validated = try host.validated()
    check(validated.name == "Production", "host name is trimmed")
} catch {
    check(false, "valid profile is accepted: \(error)")
}

do {
    let rootID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let childID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let inventory = InventoryDocument(
        groups: [
            HostGroup(id: rootID, name: "Infrastructure"),
            HostGroup(id: childID, name: "Production", parentID: rootID)
        ],
        hosts: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(inventory)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(InventoryDocument.self, from: data)
    check(decoded.schemaVersion == 3, "hierarchical inventory uses schema version 3")
    check(decoded.groups.first(where: { $0.id == childID })?.parentID == rootID,
          "nested group parent survives persistence")
} catch {
    check(false, "hierarchical inventory round trip: \(error)")
}

do {
    let legacyGroupJSON = """
    {"id":"20000000-0000-0000-0000-000000000001","name":"Legacy","createdAt":"2026-08-06T00:00:00Z"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let group = try decoder.decode(HostGroup.self, from: Data(legacyGroupJSON.utf8))
    check(group.parentID == nil, "pre-hierarchy groups migrate to the root level")
} catch {
    check(false, "pre-hierarchy group decodes: \(error)")
}

do {
    let root = HostGroup(name: "Production")
    let child = HostGroup(name: "Database", parentID: root.id)
    var host = baseHost()
    host.groupID = child.id
    host.authenticationMethod = .privateKey
    host.privateKeyPath = "/Users/example/.ssh/do-not-export-this-key"
    host.notes = "migration note"
    let data = try HostTransferService.exportData(groups: [root, child], hosts: [host])
    let text = String(decoding: data, as: UTF8.self)
    check(text.contains("myterm-host-export-v1"), "MyTerm export has a versioned format marker")
    check(!text.contains("do-not-export-this-key"), "MyTerm export excludes private-key paths")
    check(!text.contains("privateKeyPath"), "MyTerm export schema has no private-key path field")

    let payload = try HostTransferService.decodeImport(data: data)
    let merge = try HostTransferService.merge(
        existing: InventoryDocument(),
        payload: payload,
        duplicatePolicy: .skipExisting
    )
    let imported = merge.document.hosts.first
    let importedChild = imported?.groupID.flatMap { id in merge.document.groups.first { $0.id == id } }
    let importedParent = importedChild?.parentID.flatMap { id in merge.document.groups.first { $0.id == id } }
    check(merge.importedHostCount == 1 && merge.addedGroupCount == 2,
          "MyTerm export round trip imports hosts and nested groups")
    check(importedChild?.name == "Database" && importedParent?.name == "Production",
          "MyTerm export round trip preserves group hierarchy")
    check(imported?.authenticationMethod == .sshAgent && imported?.privateKeyPath.isEmpty == true,
          "imported private-key references safely fall back to SSH Agent")
} catch {
    check(false, "MyTerm secure export and round trip: \(error)")
}

let syntheticTermiusExport = Data("""
{
  "format": "myterm-termius-host-export-v1",
  "source": "Synthetic Termius test fixture",
  "groups": [
    {"sourceID": 1, "name": "Infrastructure", "parentSourceID": null},
    {"sourceID": 2, "name": "Production", "parentSourceID": 1}
  ],
  "hosts": [
    {
      "name": "Example Web",
      "hostname": "192.0.2.10",
      "port": 22,
      "username": "operator",
      "group": "Infrastructure / Production",
      "detectedPlatform": "linux",
      "hasTermiusPrivateKey": false
    },
    {
      "name": "Example Web Duplicate",
      "hostname": "192.0.2.10",
      "port": 22,
      "username": "operator",
      "group": "Infrastructure / Production",
      "detectedPlatform": "linux",
      "hasTermiusPrivateKey": false
    },
    {
      "name": "Example Key Host",
      "hostname": "198.51.100.20",
      "port": 2222,
      "username": "admin",
      "group": "Infrastructure",
      "detectedPlatform": null,
      "hasTermiusPrivateKey": true
    }
  ]
}
""".utf8)

do {
    let payload = try HostTransferService.decodeImport(data: syntheticTermiusExport)
    let merge = try HostTransferService.merge(
        existing: InventoryDocument(),
        payload: payload,
        duplicatePolicy: .skipExisting
    )
    check(payload.format == .termius, "Termius metadata export format is recognized")
    check(payload.groups.count == 2 && payload.hosts.count == 3,
          "Termius export parses groups and hosts")
    check(merge.sourceDuplicateCount == 1 && merge.importedHostCount == 2,
          "Termius duplicate connection is detected and skipped by default")
    let nestedGroup = merge.document.groups.first { $0.name == "Production" }
    let parent = nestedGroup?.parentID.flatMap { id in merge.document.groups.first { $0.id == id } }
    check(parent?.name == "Infrastructure", "Termius nested groups are reconstructed")
} catch {
    check(false, "Termius export integration import: \(error)")
}

do {
    let payload = try HostTransferService.decodeImport(data: syntheticTermiusExport)
    let selectedIndex = payload.hosts.firstIndex { $0.name == "Example Web" }!
    let selected = payload.selectingHostIndices([selectedIndex])
    let merge = try HostTransferService.merge(
        existing: InventoryDocument(),
        payload: selected,
        duplicatePolicy: .skipExisting
    )
    check(selected.hosts.count == 1, "custom import selection keeps only checked hosts")
    check(Set(selected.groups.map(\.name)) == Set(["Infrastructure", "Production"]),
          "custom import selection keeps only the required group ancestry")
    check(merge.importedHostCount == 1 && merge.addedGroupCount == 2,
          "small-scope Termius import produces one host and its two required groups")

    let privateKeyIndex = payload.hosts.firstIndex { $0.name == "Example Key Host" }!
    let privateKeySelection = payload.selectingHostIndices([privateKeyIndex])
    check(privateKeySelection.referencedPrivateKeyCount == 1,
          "custom selection recalculates private-key warnings for checked hosts")

    var duplicate = HostProfile()
    duplicate.name = "Already here"
    duplicate.hostname = selected.hosts[0].hostname
    duplicate.port = selected.hosts[0].port
    duplicate.username = selected.hosts[0].username
    let skipped = try HostTransferService.merge(
        existing: InventoryDocument(hosts: [duplicate]),
        payload: selected,
        duplicatePolicy: .skipExisting
    )
    check(skipped.importedHostCount == 0 && skipped.addedGroupCount == 0,
          "groups needed only by a skipped custom-selection duplicate are not created")
} catch {
    check(false, "custom host selection import: \(error)")
}

do {
    let group = HostGroup(name: "Existing")
    var existingHost = baseHost()
    existingHost.groupID = group.id
    let export = try HostTransferService.exportData(groups: [group], hosts: [existingHost])
    let payload = try HostTransferService.decodeImport(data: export)
    let existing = InventoryDocument(groups: [group], hosts: [existingHost])
    let skip = try HostTransferService.merge(existing: existing, payload: payload, duplicatePolicy: .skipExisting)
    let keep = try HostTransferService.merge(existing: existing, payload: payload, duplicatePolicy: .keepBoth)
    check(skip.existingConflictCount == 1 && skip.skippedDuplicateCount == 1 && skip.importedHostCount == 0,
          "default import policy does not duplicate an existing connection")
    check(keep.importedHostCount == 1 && keep.document.hosts.count == 2,
          "keep-both import policy is available when duplicate profiles are intentional")
    check(skip.addedGroupCount == 0, "matching full group paths are reused")
} catch {
    check(false, "import duplicate policy: \(error)")
}

do {
    var host = baseHost()
    host.name = ""
    host.username = ""
    let validated = try host.validated()
    check(validated.displayName == "192.0.2.10", "blank name falls back to hostname")
    check(validated.username.isEmpty, "blank default username is accepted")
} catch {
    check(false, "optional name and username are accepted: \(error)")
}

do {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-SyncJournal-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "mutation-journal.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = SyncMutationJournal(fileURL: fileURL)
    let deviceID = UUID()
    let hostID = UUID()
    let groupID = UUID()

    let initialEntries = try journal.entries()
    check(initialEntries.isEmpty, "sync mutation journal starts empty")
    let first = try journal.enqueue(
        recordID: hostID,
        recordType: .host,
        operation: .upsert,
        deviceID: deviceID
    )
    let second = try journal.enqueue(
        recordID: groupID,
        recordType: .group,
        operation: .delete,
        deviceID: deviceID
    )
    check(first.sequence == 1 && second.sequence == 2,
          "sync mutation journal assigns stable increasing sequence numbers")

    let reloaded = SyncMutationJournal(fileURL: fileURL)
    let persisted = try reloaded.entries()
    check(persisted.map(\.recordID) == [hostID, groupID],
          "sync mutation journal survives process-style reload")
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
          "sync mutation journal uses owner-only permissions")
    let journalText = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    check(!journalText.contains("hostname") && !journalText.contains("password"),
          "sync mutation journal contains no host fields or passwords")

    try reloaded.acknowledge([first.id])
    let entriesAfterAcknowledgement = try reloaded.entries()
    check(entriesAfterAcknowledgement.map(\.id) == [second.id],
          "acknowledged sync mutations are removed without dropping pending entries")
    try reloaded.removeAll()
    let entriesAfterRemoval = try reloaded.entries()
    check(entriesAfterRemoval.isEmpty, "sync mutation journal can be cleared after upload")
} catch {
    check(false, "sync mutation journal lifecycle: \(error)")
}

do {
    let record = EncryptedSyncRecord(
        id: UUID(),
        recordType: .host,
        ciphertext: Data([0x10, 0x20, 0x30]),
        nonce: Data([0x40, 0x50]),
        authenticationTag: Data([0x60, 0x70]),
        keyVersion: 1,
        formatVersion: 1,
        revision: 2,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedByDeviceID: UUID(),
        deleted: false
    )
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(EncryptedSyncRecord.self, from: data)
    check(decoded == record, "encrypted sync record survives serialization")
} catch {
    check(false, "encrypted sync record serialization: \(error)")
}

do {
    let pkce = try OAuthPKCE.generate()
    check((43...128).contains(pkce.verifier.count), "OAuth PKCE verifier length follows RFC 7636")
    check(pkce.challenge.count == 43, "OAuth PKCE S256 challenge has the expected length")
    check(
        OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "OAuth PKCE matches the RFC 7636 test vector"
    )
} catch {
    check(false, "OAuth PKCE generation: \(error)")
}

do {
    let errorPayload = Data(#"{"error":"invalid_grant","error_description":"Bad verifier\nretry"}"#.utf8)
    let diagnostic = GoogleFirebaseAuthClient.googleErrorDiagnostic(from: errorPayload)
    check(diagnostic == "invalid_grant: Bad verifier retry",
          "Google token errors expose only a bounded safe diagnostic")
    check(GoogleFirebaseAuthClient.googleErrorDiagnostic(from: Data("not-json".utf8)) == "unknown_error",
          "invalid Google token errors do not expose raw response bodies")
}

do {
    let callback = try OAuthCallback.parse(
        requestTarget: "/oauth2/callback?code=test-code&state=test-state"
    )
    check(callback.code == "test-code", "OAuth callback extracts the authorization code")
    check(callback.state == "test-state", "OAuth callback extracts state")
    check(OAuthConstantTime.equal("same-state", "same-state"), "OAuth state comparison accepts equal values")
    check(!OAuthConstantTime.equal("same-state", "other-state"), "OAuth state comparison rejects unequal values")
} catch {
    check(false, "OAuth callback parsing: \(error)")
}

do {
    let claims: [String: Any] = [
        "iss": "https://accounts.google.com",
        "aud": "123456.apps.googleusercontent.com",
        "exp": Date().addingTimeInterval(300).timeIntervalSince1970,
        "nonce": "expected-nonce"
    ]
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let token = "e30.\(OAuthBase64URL.encode(payload)).test-signature"
    try GoogleIDTokenClaimsValidator.validate(
        idToken: token,
        expectedClientID: "123456.apps.googleusercontent.com",
        expectedNonce: "expected-nonce"
    )
    check(true, "Google ID token claims bind the OAuth client and nonce")
    do {
        try GoogleIDTokenClaimsValidator.validate(
            idToken: token,
            expectedClientID: "123456.apps.googleusercontent.com",
            expectedNonce: "wrong-nonce"
        )
        check(false, "Google ID token claims reject a mismatched nonce")
    } catch OAuthSecurityError.invalidNonce {
        check(true, "Google ID token claims reject a mismatched nonce")
    }
} catch {
    check(false, "Google ID token claims validation: \(error)")
}

do {
    let plist: [String: Any] = [
        "GOOGLE_DESKTOP_CLIENT_ID": "123456.apps.googleusercontent.com",
        "GOOGLE_DESKTOP_CLIENT_SECRET": "GOCSPX-unit-test-only",
        "FIREBASE_API_KEY": "AIzaValidUnitTestKey",
        "FIREBASE_PROJECT_ID": "myterm-test"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let configuration = try CloudConfiguration.parse(data)
    check(configuration.firebaseProjectID == "myterm-test", "cloud configuration accepts a valid project")
    check(
        configuration.googleDesktopClientID.hasSuffix(".apps.googleusercontent.com"),
        "cloud configuration requires a desktop Google client ID"
    )
    check(configuration.googleDesktopClientSecret == "GOCSPX-unit-test-only",
          "cloud configuration requires the paired desktop client secret")
    let client = GoogleFirebaseAuthClient(configuration: configuration)
    let authorizationURL = try client.authorizationURL(
        redirectURI: URL(string: "http://127.0.0.1:49152/oauth2/callback")!,
        pkce: OAuthPKCE(verifier: "verifier", challenge: "challenge"),
        state: "state-value",
        nonce: "nonce-value"
    )
    let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    check(authorizationURL.scheme == "https", "Google authorization always uses HTTPS")
    check(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256",
          "Google authorization requires PKCE S256")
    check(query.first(where: { $0.name == "state" })?.value == "state-value",
          "Google authorization includes state")
    check(query.first(where: { $0.name == "scope" })?.value == "openid email profile",
          "Google authorization requests only basic identity scopes")
} catch {
    check(false, "cloud configuration parsing: \(error)")
}

do {
    let legacyJSON = """
    [{
      "id":"00000000-0000-0000-0000-000000000001",
      "name":"Legacy",
      "hostname":"192.0.2.30",
      "port":22,
      "username":"operator",
      "group":"Production",
      "authenticationMethod":"password",
      "algorithmMode":"systemDefault",
      "createdAt":"2026-08-06T00:00:00Z",
      "updatedAt":"2026-08-06T00:00:00Z"
    }]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacyHosts = try decoder.decode([HostProfile].self, from: Data(legacyJSON.utf8))
    let inventory = InventoryDocument.migrating(legacyHosts)
    check(inventory.groups.map(\.name) == ["Production"], "legacy group becomes a first-class group")
    check(inventory.hosts.first?.groupID == inventory.groups.first?.id, "legacy host keeps its group assignment")
    check(inventory.hosts.first?.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"), "legacy host UUID is preserved")
} catch {
    check(false, "legacy inventory migrates: \(error)")
}

do {
    var host = baseHost()
    host.hostname = "-oProxyCommand=bad"
    _ = try host.validated()
    check(false, "option-like hostname is rejected")
} catch HostValidationError.invalidHostname {
    check(true, "option-like hostname is rejected")
} catch {
    check(false, "option-like hostname error type")
}

do {
    var host = baseHost()
    host.username = ""
    let arguments = try SSHArgumentBuilder.arguments(for: host, usernameOverride: "temporary")
    check(arguments.last == "temporary@192.0.2.10", "connection username can be supplied per session")
} catch {
    check(false, "temporary username builds SSH arguments: \(error)")
}

do {
    var host = baseHost()
    host.algorithmMode = .custom
    host.customAlgorithms.ciphers = "aes128-ctr bad"
    _ = try host.validated()
    check(false, "whitespace in algorithm is rejected")
} catch HostValidationError.invalidAlgorithm {
    check(true, "whitespace in algorithm is rejected")
} catch {
    check(false, "custom algorithm error type")
}

do {
    let arguments = try SSHArgumentBuilder.arguments(for: baseHost())
    let knownHostsOption = arguments.first { $0.hasPrefix("UserKnownHostsFile=") }
    check(!arguments.contains("HostKeyAlgorithms=+ssh-rsa"), "default does not enable ssh-rsa")
    check(arguments.last == "operator@192.0.2.10", "destination is last argument")
    check(arguments.contains("StrictHostKeyChecking=ask"), "strict host key checking is enabled")
    check(knownHostsOption?.contains("\"\(AppPaths.knownHostsFile.path)\"") == true
          && knownHostsOption?.contains("\"\(AppPaths.importedKnownHostsRawFile.path)\"") == true,
          "known-host paths containing spaces are quoted separately")
    check(arguments.contains("PreferredAuthentications=password,keyboard-interactive"),
          "static password authentication is preferred before keyboard-interactive")
} catch {
    check(false, "default SSH arguments build: \(error)")
}

do {
    let logURL = URL(fileURLWithPath: "/private/tmp/MyTerm-auth-test.log")
    let arguments = try SSHArgumentBuilder.arguments(for: baseHost(), authenticationLogURL: logURL)
    check(arguments.contains("-v") && arguments.contains("-E") && arguments.contains(logURL.path),
          "password verification can use a private OpenSSH diagnostic log")
    check(arguments.last == "operator@192.0.2.10", "diagnostic options remain before the SSH destination")
} catch {
    check(false, "authentication diagnostic arguments build: \(error)")
}

do {
    var host = baseHost()
    host.algorithmMode = .rsaCompatibility
    let arguments = try SSHArgumentBuilder.arguments(for: host)
    check(arguments.contains("HostKeyAlgorithms=+ssh-rsa"), "RSA host-key compatibility is scoped")
    check(arguments.contains("PubkeyAcceptedAlgorithms=+ssh-rsa"), "RSA user-key compatibility is scoped")
} catch {
    check(false, "RSA arguments build: \(error)")
}

do {
    var host = baseHost()
    host.algorithmMode = .custom
    host.customAlgorithms.keyExchangeAlgorithms = "+diffie-hellman-group14-sha1"
    let arguments = try SSHArgumentBuilder.arguments(for: host)
    check(arguments.contains("KexAlgorithms=+diffie-hellman-group14-sha1"), "custom KEX is a separate argument")
} catch {
    check(false, "custom arguments build: \(error)")
}

let environment = SSHEnvironmentBuilder.environment(from: [
    "USER": "tester",
    "HOME": "/Users/tester",
    "SSH_AUTH_SOCK": "/tmp/agent.sock",
    "UNRELATED_SECRET": "must-not-pass"
])
check(environment.contains("SSH_AUTH_SOCK=/tmp/agent.sock"), "SSH agent socket is preserved")
check(!environment.contains { $0.contains("UNRELATED_SECRET") }, "unrelated environment secrets are filtered")

let localEnvironment = LocalTerminalEnvironmentBuilder.environment(from: [
    "USER": "tester",
    "HOME": "/Users/tester",
    "UNRELATED_SECRET": "must-not-pass"
])
check(localEnvironment.contains("SHELL=/bin/zsh"), "local terminal uses the fixed system zsh")
check(!localEnvironment.contains { $0.contains("UNRELATED_SECRET") }, "local terminal filters unrelated environment secrets")
check(
    LocalTerminalEnvironmentBuilder.currentDirectory()
        == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
    "local terminal starts in the current macOS user's home directory"
)

do {
    let suiteName = "MyTerm.ShortcutTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        check(false, "shortcut test defaults are available")
        throw CocoaError(.fileReadUnknown)
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = AppShortcutStore(defaults: defaults)
    check(store.shortcut(for: .pasteSavedPassword)?.displayText == "⌘P",
          "saved-password shortcut defaults to Command-P")
    check(store.shortcut(for: .openHosts) == nil,
          "shortcuts can be disabled by default")

    let custom = AppShortcutDefinition(
        keyCode: 40,
        key: "K",
        modifiers: [.command, .option]
    )
    try store.assign(custom, to: .pasteSavedPassword)
    let reloaded = AppShortcutStore(defaults: defaults)
    check(reloaded.shortcut(for: .pasteSavedPassword) == custom,
          "custom shortcuts persist in local preferences")

    do {
        try store.assign(custom, to: .copyTerminal)
        check(false, "duplicate shortcuts are rejected")
    } catch AppShortcutAssignmentError.conflict(.pasteSavedPassword) {
        check(true, "duplicate shortcuts are rejected")
    } catch {
        check(false, "duplicate shortcut conflict identifies the existing action")
    }

    try store.assign(nil, to: .pasteSavedPassword)
    check(AppShortcutStore(defaults: defaults).shortcut(for: .pasteSavedPassword) == nil,
          "disabled shortcuts remain disabled after relaunch")

    do {
        try store.assign(.command(keyCode: 12, key: "Q"), to: .openHosts)
        check(false, "essential macOS shortcuts are reserved")
    } catch AppShortcutAssignmentError.reserved {
        check(true, "essential macOS shortcuts are reserved")
    } catch {
        check(false, "reserved shortcut reports the expected error")
    }
} catch {
    check(false, "shortcut settings round trip: \(error)")
}

let knownHostsFixture = """
# ignored comment
example.test ssh-ed25519 AQID imported
@revoked [192.0.2.40]:2222 ssh-rsa BAUG
|1|c2FsdA==|aGFzaA== ecdsa-sha2-nistp256 BwgJ
invalid line
example.test ssh-ed25519 AQID imported
"""
let parsedKnownHosts = KnownHostsParser.parse(knownHostsFixture)
check(parsedKnownHosts.count == 3, "known_hosts parser ignores comments, invalid lines and duplicates")
check(parsedKnownHosts.contains { $0.marker == "@revoked" }, "known_hosts markers are preserved")
check(parsedKnownHosts.contains { $0.isHashed }, "hashed known_hosts entries remain private")
check(parsedKnownHosts.first { $0.hostField == "example.test" }?.fingerprint.hasPrefix("SHA256:") == true,
      "known_hosts public-key fingerprint is calculated")

var platformDetector = HostPlatformDetector()
check(platformDetector.consume(Array("system-release -> alma".utf8)[...]) == nil,
      "platform detector waits for split evidence")
check(platformDetector.consume(Array("linux-release".utf8)[...]) == .almaLinux,
      "platform detector recognizes AlmaLinux output")
check(platformDetector.consume(Array("Ubuntu release".utf8)[...]) == nil,
      "platform detector records a platform only once")

do {
    var serial = SerialConfiguration()
    serial.devicePath = "/dev/cu.MyTerm-Test"
    serial.baudRate = 115_200
    serial.dataBits = 7
    serial.stopBits = 2
    serial.parity = .even
    serial.flowControl = .xonXoff
    let validated = try serial.validated(requireExistingDevice: false)
    check(validated.screenMode.contains("115200,cs7,ixon,ixoff"), "serial screen mode is explicit")
    check(validated.sttyArguments.contains("cstopb") && validated.sttyArguments.contains("-parodd"),
          "serial advanced stop-bit and parity settings are explicit")
} catch {
    check(false, "valid serial configuration is accepted: \(error)")
}

do {
    var serial = SerialConfiguration()
    serial.devicePath = "/dev/cu.safe\nmalicious"
    _ = try serial.validated(requireExistingDevice: false)
    check(false, "unsafe serial device path is rejected")
} catch SerialConfigurationError.invalidDevice {
    check(true, "unsafe serial device path is rejected")
} catch {
    check(false, "unsafe serial device path error type")
}

var promptDetector = LoginPasswordPromptDetector()
check(!promptDetector.consume(Array("operator@host's pass".utf8)[...]), "split password prompt waits")
check(promptDetector.consume(Array("word: ".utf8)[...]), "split password prompt is detected")
check(!promptDetector.consume(Array("[sudo] password: ".utf8)[...]), "login password auto-fill runs only once")

var passwordPromptState = PasswordPromptStateDetector()
check(passwordPromptState.consume(Array("[sudo] pass".utf8)[...]) == nil,
      "manual password gate waits for a complete prompt")
check(passwordPromptState.consume(Array("word for operator: \u{1B}[?25h".utf8)[...]) == true,
      "manual password gate recognizes a sudo prompt with terminal escapes")
check(passwordPromptState.userDidSendInput() == false && !passwordPromptState.isAwaitingPassword,
      "any user input closes the manual password gate")
check(passwordPromptState.consume(Array("[operator@host ~]$ ".utf8)[...]) == nil,
      "ordinary shell prompts do not open the password gate")
check(passwordPromptState.consume(Array("operator 的密碼：".utf8)[...]) == true,
      "localized password prompts can open the password gate")
check(passwordPromptState.consume(Array("\nlogin complete".utf8)[...]) == false,
      "subsequent terminal output closes the password gate")
check(passwordPromptState.consume(Array("\nNew password:".utf8)[...]) == nil,
      "password-change and confirmation prompts do not open the saved-password gate")

var passwordCapture = LoginPasswordCapture()
check(passwordCapture.consume(Array("ignored".utf8)[...]) == .none,
      "password bytes are not captured before an SSH login prompt")
passwordCapture.begin()
check(passwordCapture.consume(Array("secrex".utf8)[...]) == .none,
      "password capture waits for submission")
_ = passwordCapture.consume([0x7F][...])
let correctedCapture = passwordCapture.consume(Array("t\r".utf8)[...])
check(correctedCapture == .submitted(Data("secret".utf8)),
      "password capture mirrors backspace and returns only the submitted attempt")
check(!passwordCapture.isCapturing, "password capture stops after one submitted attempt")

passwordCapture.begin()
_ = passwordCapture.consume(Array("wrong".utf8)[...])
_ = passwordCapture.consume([0x15][...])
let controlUResult = passwordCapture.consume(Array("correct\n".utf8)[...])
check(controlUResult == .submitted(Data("correct".utf8)),
      "Control-U removes an incorrect password before submission")

passwordCapture.begin()
check(passwordCapture.consume([0x03][...]) == .cancelled && !passwordCapture.isCapturing,
      "Control-C cancels password retention")

var authLogDetector = SSHAuthenticationLogDetector()
check(authLogDetector.consume(Array("debug1: Authenticated to 192.0.".utf8)[...]) == nil,
      "split OpenSSH authentication evidence waits for completion")
check(authLogDetector.consume(Array("2.9 ([192.0.2.9]:22) using \"password\".\n".utf8)[...]) == .password,
      "OpenSSH password success evidence is recognized")

var keyboardInteractiveDetector = SSHAuthenticationLogDetector()
let keyboardInteractiveResult = keyboardInteractiveDetector.consume(
    Array("Authenticated to host ([192.0.2.1]:22) using \"keyboard-interactive\".\n".utf8)[...]
)
check(keyboardInteractiveResult == .other("keyboard-interactive"),
      "keyboard-interactive success is distinguished from a reusable password")

do {
    let authenticationLog = try AppPaths.createAuthenticationLog()
    let attributes = try FileManager.default.attributesOfItem(atPath: authenticationLog.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    check(permissions == 0o600, "OpenSSH authentication diagnostics use owner-only permissions")
    AppPaths.removeAuthenticationLog(authenticationLog)
    check(!FileManager.default.fileExists(atPath: authenticationLog.path),
          "OpenSSH authentication diagnostics are removed after use")
} catch {
    check(false, "authentication diagnostic file lifecycle: \(error)")
}

let keychainTestID = UUID()
do {
    let result = try KeychainStore.deletionResult(for: errSecInvalidOwnerEdit)
    check(result == .manualCleanupRequired(errSecInvalidOwnerEdit),
          "Keychain owner mismatch becomes a non-blocking cleanup result")
    let missingResult = try KeychainStore.deletionResult(for: errSecItemNotFound)
    check(missingResult == .notFound,
          "missing Keychain password is safe to delete")
} catch {
    check(false, "Keychain deletion status classification: \(error)")
}

do {
    try KeychainStore.save(password: "MySSHClient-temporary-test", for: keychainTestID)
    let stored = try KeychainStore.passwordData(for: keychainTestID)
    check(stored == Data("MySSHClient-temporary-test".utf8), "Keychain secret round trip")
    try KeychainStore.deletePassword(for: keychainTestID)
    let deleted = try KeychainStore.passwordData(for: keychainTestID)
    check(deleted == nil, "Keychain test secret is deleted")
} catch {
    _ = try? KeychainStore.deletePassword(for: keychainTestID)
    check(false, "Keychain operations: \(error)")
}

let cloudKeychainTestProject = "myterm-unit-test-\(UUID().uuidString)"
do {
    try CloudSessionKeychainStore.saveRefreshToken(
        "firebase-refresh-token-test",
        projectID: cloudKeychainTestProject
    )
    let stored = try CloudSessionKeychainStore.refreshToken(projectID: cloudKeychainTestProject)
    check(stored == "firebase-refresh-token-test", "Firebase refresh token uses its own Keychain service")
    _ = try CloudSessionKeychainStore.deleteRefreshToken(projectID: cloudKeychainTestProject)
    let deleted = try CloudSessionKeychainStore.refreshToken(projectID: cloudKeychainTestProject)
    check(deleted == nil, "Firebase refresh token test item is deleted")
} catch {
    _ = try? CloudSessionKeychainStore.deleteRefreshToken(projectID: cloudKeychainTestProject)
    check(false, "Firebase refresh token Keychain operations: \(error)")
}

print("\n\(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
