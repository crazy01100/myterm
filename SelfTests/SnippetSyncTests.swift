import Foundation

final class SnippetMemoryBackend: SnippetSyncBackend {
    var records: [UUID: SnippetCloudDocument] = [:]
    var failAfterWrite = false
    var beforeWrite: (@MainActor () throws -> Void)?
    func fetch(ownerUID: String, idToken: String) async throws -> [SnippetCloudDocument] { Array(records.values) }
    func write(_ record: EncryptedSyncRecord, expectedUpdateTime: String?, ownerUID: String, idToken: String) async throws {
        if let beforeWrite { self.beforeWrite = nil; try await beforeWrite() }
        guard records[record.id]?.updateTime == expectedUpdateTime else { throw FirestoreSnippetBackendError.documentAlreadyExists }
        records[record.id] = .init(record: record, updateTime: "revision-\(record.revision)")
        if failAfterWrite { failAfterWrite = false; throw URLError(.networkConnectionLost) }
    }
}

final class SnippetURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct SnippetSyncTests {
    static var passed = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError("FAIL: \(message)") }
        passed += 1; print("PASS: \(message)")
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); check(false, message) } catch { check(true, message) }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = "demo-myterm", uid = "test-only"
        let scope = SnippetSyncPolicy.scope(project: project, uid: uid)
        let key = try VaultMasterKey(rawRepresentation: Data(repeating: 5, count: 32), version: 1)
        let backend = SnippetMemoryBackend(), device = UUID()
        func make(_ name: String) throws -> CommandSnippetStore {
            let store = CommandSnippetStore(fileURL: root.appendingPathComponent(name + "/snippets.json"))
            store.bindScope(scope); try store.prepareUnifiedSync(scope: scope, enabled: true); return store
        }
        let switchStore = CommandSnippetStore(fileURL: root.appendingPathComponent("switch/snippets.json"))
        let localFixture = CommandSnippet(title: "offline", command: "pwd")
        try switchStore.save(localFixture); switchStore.bindScope(scope)
        let beforeOff = try Data(contentsOf: root.appendingPathComponent("switch/snippets.json"))
        check(try !switchStore.prepareUnifiedSync(scope: scope, enabled: false), "unified switch off does not prepare snippet sync")
        check(!switchStore.hasSyncScope && switchStore.snippets == [localFixture], "off preserves local library without separate enrollment")
        check(try Data(contentsOf: root.appendingPathComponent("switch/snippets.json")) == beforeOff, "off does not migrate or write pending state")
        try switchStore.prepareUnifiedSync(scope: scope, enabled: true)
        check(switchStore.hasSyncScope && switchStore.snippets == [localFixture], "existing unified switch on automatically includes snippets")
        let firstMigration = try Data(contentsOf: root.appendingPathComponent("switch/snippets.json"))
        try switchStore.prepareUnifiedSync(scope: scope, enabled: true)
        check(try Data(contentsOf: root.appendingPathComponent("switch/snippets.json")) == firstMigration, "repeated on does not rewrite or duplicate migration")
        try switchStore.prepareUnifiedSync(scope: scope, enabled: false)
        check(switchStore.snippets == [localFixture], "turning off retains commands")
        let a = try make("a"), b = try make("b")
        func sync(_ store: CommandSnippetStore, backend: SnippetMemoryBackend = backend) async throws -> SnippetSyncPass {
            let generation = store.generation
            return try await SnippetSyncEngine.perform(store: store, project: project, uid: uid, token: "test", key: key,
                deviceID: device, backend: backend, validate: { try store.validateScope(scope, generation: generation) })
        }
        var value = CommandSnippet(title: "test", command: "pwd", category: "system", note: "中文說明")
        try a.save(value); _ = try await sync(a); _ = try await sync(b)
        check(b.snippets == a.snippets, "new record reaches second independent local store")
        value.command = "whoami"; try b.save(value); _ = try await sync(b); _ = try await sync(a)
        check(a.snippets.first?.command == "whoami", "reverse edit synchronizes")
        let encrypted = backend.records[value.id]!.record
        check(!String(decoding: encrypted.ciphertext, as: UTF8.self).contains("whoami"), "backend receives ciphertext")
        rejects("wrong UID rejected") { _ = try CommandSnippetSyncCodec.decrypt(encrypted, projectID: project, ownerUID: "other", masterKey: key) }
        rejects("wrong project rejected") { _ = try CommandSnippetSyncCodec.decrypt(encrypted, projectID: "other", ownerUID: uid, masterKey: key) }
        let wrong = try VaultMasterKey(rawRepresentation: Data(repeating: 6, count: 32), version: 1)
        rejects("wrong key rejected") { _ = try CommandSnippetSyncCodec.decrypt(encrypted, projectID: project, ownerUID: uid, masterKey: wrong) }
        let tampered = EncryptedSyncRecord(id: UUID(), recordType: .commandSnippet, ciphertext: encrypted.ciphertext,
            nonce: encrypted.nonce, authenticationTag: encrypted.authenticationTag, keyVersion: encrypted.keyVersion,
            formatVersion: encrypted.formatVersion, revision: encrypted.revision, modifiedAt: encrypted.modifiedAt,
            modifiedByDeviceID: encrypted.modifiedByDeviceID, deleted: false)
        rejects("changed identity rejected") { _ = try CommandSnippetSyncCodec.decrypt(tampered, projectID: project, ownerUID: uid, masterKey: key) }
        value.command = "uptime"; try a.save(value)
        var competing = value; competing.command = "df -h"; try b.save(competing)
        _ = try await sync(a)
        check(try await sync(b) == .conflicts, "concurrent edits retain conflict copy")
        check(b.snippets.contains { $0.command == "df -h" } && b.snippets.contains { $0.command == "uptime" }, "both command bodies retained")
        _ = try await sync(b)
        check(b.snippets.count == 2, "repeat pass does not duplicate conflict copies")
        let conflict = b.snippets.first { $0.id != value.id }!
        try b.approveConflict(conflict.id); _ = try await sync(b); _ = try await sync(a)
        check(a.snippets.count == 2, "reviewed copy propagates")
        try a.delete(value.id); _ = try await sync(a)
        competing.command = "hostname"; try b.save(competing)
        _ = try await sync(b)
        check(!b.snippets.contains { $0.id == value.id } && b.snippets.contains { $0.command == "hostname" }, "remote delete preserves offline edit as new review copy")
        check(backend.records[value.id]?.record.deleted == true, "deleted original never resurrected")
        let c = try make("c"); _ = try await sync(c)
        check(!c.snippets.contains { $0.id == value.id }, "new device honors tombstone")
        let offline = CommandSnippet(title: "response-loss", command: "date")
        try c.save(offline); backend.failAfterWrite = true
        do { _ = try await sync(c); check(false, "lost response") } catch { check(true, "lost response remains retryable") }
        _ = try await sync(c)
        check(backend.records[offline.id]?.record.revision == 1, "retry after accepted write does not duplicate or increment")
        var inflight = offline; inflight.command = "id"; try c.save(inflight)
        backend.beforeWrite = { [c] in
            var newer = inflight; newer.command = "uname"; try c.save(newer)
        }
        check(try await sync(c) == .pending, "edit during upload remains pending")
        check(c.snippets.first { $0.id == offline.id }?.command == "uname", "ack preserves newer local edit")
        _ = try await sync(c)
        let remote = try CommandSnippetSyncCodec.decrypt(backend.records[offline.id]!.record, projectID: project, ownerUID: uid, masterKey: key)
        check(remote.value?.command == "uname", "next pass sends newer edit")
        let restored = CommandSnippetStore(fileURL: root.appendingPathComponent("c/snippets.json"))
        restored.bindScope(scope)
        check(restored.snippets == c.snippets && restored.hasSyncScope, "restart restores scope and baseline")
        let oldGeneration = restored.generation
        let otherScope = SnippetSyncPolicy.scope(project: project, uid: "other")
        restored.bindScope(otherScope)
        check(restored.snippets.isEmpty && !restored.hasSyncScope, "new account sees no previous account commands")
        rejects("old account response cannot merge") { try restored.mergeRemote([], scope: scope, generation: oldGeneration) }
        try restored.prepareUnifiedSync(scope: otherScope, enabled: true)
        check(restored.snippets.isEmpty, "enrollment does not import another account")
        restored.bindScope(scope)
        check(restored.snippets == c.snippets, "return to original account restores retained copy")
        let original = restored.snippets[0]; var edited = original; edited.command = "different"
        try restored.save(edited)
        rejects("stale editor cannot overwrite remote or local change") { try restored.saveEdited(original, original: original, scope: scope) }
        let legacyURL = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(CommandSnippetDocument(snippets: [offline])).write(to: legacyURL)
        let legacy = CommandSnippetStore(fileURL: legacyURL)
        legacy.bindScope(scope)
        check(legacy.snippets == [offline] && !legacy.hasSyncScope, "existing local snippets remain visible before first enrollment")
        try legacy.prepareUnifiedSync(scope: scope, enabled: true)
        check(legacy.snippets == [offline] && legacy.unboundCount == 0, "legacy migration and first enrollment preserve IDs exactly once")
        let repeatLoad = CommandSnippetStore(fileURL: legacyURL); repeatLoad.bindScope(scope)
        check(repeatLoad.snippets == [offline], "migration survives restart")
        let baseline = c.partition
        rejects("missing previously confirmed cloud record fails closed") { _ = try SnippetSyncPolicy.merge(baseline, remote: []) }
        let duplicate = SnippetRemoteValue(id: offline.id, value: offline, revision: 1)
        rejects("duplicate cloud IDs rejected without dictionary trap") { _ = try SnippetSyncPolicy.merge(.init(), remote: [duplicate, duplicate]) }
        let escaped = CommandSnippet(title: "escaped", command: String(repeating: "\u{0}", count: 16384))
        let escapedRecord = try CommandSnippetSyncCodec.encrypt(.init(id: escaped.id, value: escaped, revision: 1), projectID: project, ownerUID: uid, masterKey: key, deviceID: device)
        check(escapedRecord.ciphertext.count > 65536 && escapedRecord.ciphertext.count <= 131072, "escaped maximum command fits explicit 128KiB envelope")
        check(try CommandSnippetSyncCodec.decrypt(escapedRecord, projectID: project, ownerUID: uid, masterKey: key).value == escaped, "maximum escaped payload roundtrips")
        let partition = SnippetSyncPartition(enrolled: true, entries: [.init(id: offline.id, value: nil, baseline: offline, revision: 1)])
        var remoteEdit = offline; remoteEdit.command = "remote-edit"
        let deletionWins = try SnippetSyncPolicy.merge(partition, remote: [.init(id: offline.id, value: remoteEdit, revision: 2)])
        check(deletionWins.entries.first { $0.id == offline.id }?.value == nil && deletionWins.entries.contains { $0.needsReview && $0.value?.command == "remote-edit" }, "local deletion and remote edit retain both intents")
        let transportConfig = URLSessionConfiguration.ephemeral
        transportConfig.protocolClasses = [SnippetURLProtocol.self]
        let transport = URLSession(configuration: transportConfig)
        defer { transport.invalidateAndCancel(); SnippetURLProtocol.handler = nil }
        let http = FirestoreSnippetBackend(projectID: project, session: transport)
        let fixture = try CommandSnippetSyncCodec.encrypt(.init(id: offline.id, value: offline, revision: 1), projectID: project, ownerUID: uid, masterKey: key, deviceID: device)
        func document(_ record: EncryptedSyncRecord) -> [String: Any] {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ["name": "projects/\(project)/databases/(default)/documents/users/\(uid)/commandSnippets/\(record.id.uuidString.lowercased())",
                    "updateTime": "2026-09-21T00:00:00.123456Z", "fields": [
                        "recordType": ["stringValue": "commandSnippet"],
                        "ciphertext": ["bytesValue": record.ciphertext.base64EncodedString()],
                        "nonce": ["bytesValue": record.nonce.base64EncodedString()],
                        "authenticationTag": ["bytesValue": record.authenticationTag.base64EncodedString()],
                        "keyVersion": ["integerValue": "1"], "formatVersion": ["integerValue": "1"],
                        "revision": ["integerValue": String(record.revision)], "deleted": ["booleanValue": record.deleted],
                        "modifiedAt": ["timestampValue": formatter.string(from: record.modifiedAt)],
                        "modifiedByDeviceID": ["stringValue": record.modifiedByDeviceID.uuidString.lowercased()]
                    ]]
        }
        let doc = document(fixture)
        SnippetURLProtocol.handler = { request in
            guard request.url!.path.contains("/commandSnippets"), request.value(forHTTPHeaderField: "Authorization") == "Bearer test" else { throw SnippetSyncError.invalidData }
            return (200, try JSONSerialization.data(withJSONObject: ["documents": [doc]]))
        }
        let fetched = try await http.fetch(ownerUID: uid, idToken: "test")
        check(fetched.count == 1 && fetched[0].record == fixture && fetched[0].updateTime == "2026-09-21T00:00:00.123456Z", "REST decoder preserves ciphertext and exact server precondition")
        SnippetURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            guard request.httpMethod == "PATCH", query.contains(where: { $0.name == "currentDocument.exists" && $0.value == "false" }) else { throw SnippetSyncError.invalidData }
            return (200, try JSONSerialization.data(withJSONObject: doc))
        }
        try await http.write(fixture, expectedUpdateTime: nil, ownerUID: uid, idToken: "test")
        check(true, "new REST record uses create-only precondition and validates response")
        let update = try CommandSnippetSyncCodec.encrypt(.init(id: offline.id, value: offline, revision: 2), projectID: project, ownerUID: uid, masterKey: key, deviceID: device)
        SnippetURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            guard query.contains(where: { $0.name == "currentDocument.updateTime" && $0.value == fetched[0].updateTime }) else { throw SnippetSyncError.invalidData }
            return (200, try JSONSerialization.data(withJSONObject: document(update)))
        }
        try await http.write(update, expectedUpdateTime: fetched[0].updateTime, ownerUID: uid, idToken: "test")
        check(true, "updates use exact updateTime instead of blind overwrite")
        SnippetURLProtocol.handler = { _ in (412, Data()) }
        do { try await http.write(update, expectedUpdateTime: fetched[0].updateTime, ownerUID: uid, idToken: "test"); check(false, "CAS conflict") }
        catch FirestoreSnippetBackendError.documentAlreadyExists { check(true, "REST CAS failure prevents overwrite") }
        SnippetURLProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["documents": [doc, doc]])) }
        do { _ = try await http.fetch(ownerUID: uid, idToken: "test"); check(false, "duplicate response") }
        catch { check(true, "REST duplicate IDs rejected") }
        var foreign = doc; foreign["name"] = "projects/other/databases/(default)/documents/users/other/commandSnippets/\(offline.id.uuidString.lowercased())"
        SnippetURLProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["documents": [foreign]])) }
        do { _ = try await http.fetch(ownerUID: uid, idToken: "test"); check(false, "foreign response") }
        catch { check(true, "REST foreign document path rejected") }
        SnippetURLProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["documents": [], "nextPageToken": "repeat"])) }
        do { _ = try await http.fetch(ownerUID: uid, idToken: "test"); check(false, "pagination loop") }
        catch { check(true, "REST pagination loop bounded") }
        let full = SnippetSyncPartition(enrolled: true, entries: (0..<500).map { _ in let x = CommandSnippet(title: "max", command: "pwd"); return .init(id: x.id, value: x, baseline: nil) })
        rejects("merge over record capacity preserves source") { _ = try SnippetSyncPolicy.merge(full, remote: [duplicate]) }
        var failWrites = false
        let failure = CommandSnippetStore(fileURL: root.appendingPathComponent("fail/snippets.json"), persist: { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try CommandSnippetStore.writePrivateFile(data, to: url)
        })
        failure.bindScope(scope); try failure.prepareUnifiedSync(scope: scope, enabled: true)
        try failure.save(offline)
        failWrites = true
        rejects("failed merge cannot advance baseline") { try failure.mergeRemote([duplicate], scope: scope, generation: failure.generation) }
        check(failure.partition.entries.first?.revision == 0 && failure.snippets == [offline], "disk failure keeps local content and pending intent")
        failWrites = false
        try failure.mergeRemote([duplicate], scope: scope, generation: failure.generation)
        check(failure.partition.entries.first?.revision == 1, "durable retry advances baseline once")
        let cancelled = try make("cancel")
        let cancelItem = CommandSnippet(title: "cancel", command: "pwd"); try cancelled.save(cancelItem)
        backend.beforeWrite = { cancelled.bindScope(otherScope) }
        do { _ = try await sync(cancelled); check(false, "context change during upload") }
        catch { check(true, "in-flight account switch refuses old acknowledgment") }
        check(cancelled.snippets.isEmpty, "in-flight response never populates new account")
        print("\(passed) snippet sync checks passed, 0 failed")
    }
}
