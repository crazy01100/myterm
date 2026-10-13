import Foundation

final class BookmarkMemoryBackend: BookmarkSyncBackend {
    var records: [UUID: BookmarkCloudDocument] = [:]
    var failAfterWrite = false
    var beforeWrite: (@MainActor () throws -> Void)?
    func fetch(ownerUID: String, idToken: String) async throws -> [BookmarkCloudDocument] { Array(records.values) }
    func write(_ record: EncryptedSyncRecord, expectedUpdateTime: String?, ownerUID: String, idToken: String) async throws {
        if let beforeWrite { self.beforeWrite = nil; try await beforeWrite() }
        guard records[record.id]?.updateTime == expectedUpdateTime else { throw FirestoreBookmarkBackendError.documentAlreadyExists }
        records[record.id] = .init(record: record, updateTime: "revision-\(record.revision)")
        if failAfterWrite { failAfterWrite = false; throw URLError(.networkConnectionLost) }
    }
}

final class BookmarkURLProtocol: URLProtocol {
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

@main struct SFTPBookmarkTests {
    static var passed = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError("FAIL: \(message)") }
        passed += 1; print("PASS: \(message)")
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); check(false, message) } catch { check(true, message) }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = "demo-myterm", uid = "fixture-owner"
        let scope = BookmarkSyncPolicy.scope(project: project, uid: uid)
        let other = BookmarkSyncPolicy.scope(project: project, uid: "fixture-other")
        let key = try VaultMasterKey(rawRepresentation: Data(repeating: 5, count: 32), version: 1)
        let device = UUID(), backend = BookmarkMemoryBackend()
        let target = SFTPBookmarkTarget(hostID: UUID(), hostname: "example.invalid", port: 22, username: "fixture")
        func item(_ title: String, _ path: String) -> RemoteDirectoryBookmark { .init(title: title, path: path, target: target) }
        func make(_ name: String) throws -> SFTPBookmarkStore {
            let store = SFTPBookmarkStore(fileURL: root.appendingPathComponent(name + "/bookmarks.json"))
            store.bindScope(scope); try store.prepareUnifiedSync(scope: scope, enabled: true)
            return store
        }
        func sync(_ store: SFTPBookmarkStore, backend: BookmarkMemoryBackend = backend) async throws -> BookmarkSyncPass {
            let generation = store.generation
            return try await SFTPBookmarkSyncEngine.perform(store: store, project: project, uid: uid, token: "test", key: key,
                deviceID: device, backend: backend, validate: { try store.validateScope(scope, generation: generation) })
        }
        let a = try make("a"), b = try make("b")
        let local = LocalDirectoryBookmark(title: "local secret", path: "/private/local-only")
        try a.saveLocal(local, original: nil)
        check(a.changeRevision == 1, "local-only save does not request cloud sync after enrollment")
        _ = try await sync(a); _ = try await sync(b)
        check(backend.records.isEmpty && b.localBookmarks.isEmpty, "local bookmark never enters cloud collection")
        var value = item("initial", "/srv/資料")
        try a.save(value); _ = try await sync(a); _ = try await sync(b)
        check(b.bookmarks == [value] && b.localBookmarks.isEmpty, "remote bookmark reaches second Mac without local bookmarks")
        let encrypted = backend.records[value.id]!.record
        check(!String(decoding: encrypted.ciphertext, as: UTF8.self).contains(value.path), "path encrypted")
        let payload = try SFTPBookmarkSyncCodec.decrypt(encrypted, projectID: project, ownerUID: uid, masterKey: key)
        let encodedPayload = try JSONEncoder().encode(payload.value)
        check(payload.value == value && !String(decoding: encodedPayload, as: UTF8.self).contains(local.path), "decrypted remote payload excludes local path")
        rejects("wrong owner rejected") { _ = try SFTPBookmarkSyncCodec.decrypt(encrypted, projectID: project, ownerUID: "other", masterKey: key) }
        rejects("wrong project rejected") { _ = try SFTPBookmarkSyncCodec.decrypt(encrypted, projectID: "other", ownerUID: uid, masterKey: key) }
        let wrongKey = try VaultMasterKey(rawRepresentation: Data(repeating: 6, count: 32), version: 1)
        rejects("wrong key rejected") { _ = try SFTPBookmarkSyncCodec.decrypt(encrypted, projectID: project, ownerUID: uid, masterKey: wrongKey) }
        let tampered = EncryptedSyncRecord(id: UUID(), recordType: .sftpBookmark, ciphertext: encrypted.ciphertext, nonce: encrypted.nonce,
            authenticationTag: encrypted.authenticationTag, keyVersion: 1, formatVersion: 1, revision: 1,
            modifiedAt: encrypted.modifiedAt, modifiedByDeviceID: device, deleted: false)
        rejects("identity tampering rejected") { _ = try SFTPBookmarkSyncCodec.decrypt(tampered, projectID: project, ownerUID: uid, masterKey: key) }
        value.title = "renamed"; try b.save(value); _ = try await sync(b); _ = try await sync(a)
        check(a.bookmarks == [value], "reverse rename synchronizes")
        var localEdit = value; localEdit.title = "A edit"; try a.save(localEdit)
        var otherEdit = value; otherEdit.title = "B edit"; try b.save(otherEdit)
        _ = try await sync(a)
        check(try await sync(b) == .conflicts, "concurrent rename needs review")
        check(Set(b.bookmarks.map(\.title)) == ["A edit", "B edit"], "both rename candidates retained")
        let review = b.bookmarks.first { b.needsReview($0.id) }!
        _ = try await sync(b); check(b.bookmarks.count == 2, "repeated conflict is idempotent")
        try b.resolve(review, scope: scope); _ = try await sync(b); _ = try await sync(a)
        check(a.bookmarks.count == 1 && a.bookmarks[0].title == "B edit", "review selects one name for same location")
        try a.delete(value.id); _ = try await sync(a)
        otherEdit.title = "offline edit"; try b.save(otherEdit)
        check(try await sync(b) == .conflicts, "delete against edit preserves review candidate")
        check(backend.records[value.id]!.record.deleted && !b.bookmarks.contains { $0.id == value.id }, "deleted UUID never resurrected")
        try b.resolve(b.bookmarks.first!, scope: scope); _ = try await sync(b); _ = try await sync(a)
        check(a.bookmarks.count == 1 && a.bookmarks[0].id != value.id, "explicit restore creates a new UUID")
        let duplicates = BookmarkMemoryBackend(), da = try make("da"), db = try make("db")
        let daValue = item("same", "/duplicate"), dbValue = item("same", "/duplicate")
        try da.save(daValue); try db.save(dbValue)
        _ = try await sync(da, backend: duplicates); _ = try await sync(db, backend: duplicates)
        _ = try await sync(da, backend: duplicates); _ = try await sync(db, backend: duplicates)
        check(da.bookmarks.count == 1 && da.bookmarks == db.bookmarks, "different UUID same location coalesces across Macs")
        let dc = try make("dc"); try dc.save(item("different name", "/duplicate"))
        check(try await sync(dc, backend: duplicates) == .conflicts, "duplicate with different name retains candidate")
        let originalCount = dc.bookmarks.count
        _ = try await sync(dc, backend: duplicates)
        check(dc.bookmarks.count == originalCount, "semantic conflict does not multiply")
        var offline = item("response-loss", "/retry")
        try a.save(offline); backend.failAfterWrite = true
        do { _ = try await sync(a); check(false, "lost reply") } catch { check(true, "lost reply leaves pending data") }
        _ = try await sync(a)
        check(backend.records[offline.id]!.record.revision == 1, "lost reply retry does not duplicate write")
        offline.title = "inflight"; try a.save(offline)
        backend.beforeWrite = { var newer = offline; newer.title = "newer"; try a.save(newer) }
        check(try await sync(a) == .pending, "edit during upload stays pending")
        _ = try await sync(a)
        check(a.bookmarks.first { $0.id == offline.id }?.title == "newer", "ack preserves newer local edit")
        let restored = SFTPBookmarkStore(fileURL: root.appendingPathComponent("a/bookmarks.json")); restored.bindScope(scope)
        check(restored.bookmarks == a.bookmarks && restored.localBookmarks == [local], "restart restores both kinds and baseline")
        restored.bindScope(nil)
        check(restored.bookmarks.isEmpty && restored.localBookmarks == [local], "explicit sign-out hides account remote bookmarks only")
        restored.bindScope(other); try restored.prepareUnifiedSync(scope: other, enabled: true)
        check(restored.bookmarks.isEmpty, "switch account does not enroll previous account data")
        restored.bindScope(scope); check(restored.bookmarks == a.bookmarks, "switch back restores original scope")
        let generation = restored.generation
        restored.bindScope(other)
        rejects("stale account response rejected") { try restored.mergeRemote([], scope: scope, generation: generation) }
        let unbound = SFTPBookmarkStore(fileURL: root.appendingPathComponent("unbound/bookmarks.json"))
        try unbound.save(item("unbound", "/new")); unbound.bindScope(scope)
        check(try !unbound.prepareUnifiedSync(scope: scope, enabled: false), "off prevents enrollment")
        try unbound.prepareUnifiedSync(scope: scope, enabled: true)
        check(unbound.bookmarks.count == 1 && unbound.unboundCount == 0, "single switch enrolls unbound remote exactly once")
        try unbound.prepareUnifiedSync(scope: scope, enabled: true); check(unbound.bookmarks.count == 1, "enrollment is idempotent")
        let stale = unbound.bookmarks[0]; var changed = stale; changed.title = "changed"; try unbound.save(changed)
        rejects("stale rename rejected") { try unbound.saveEdited(stale, original: stale, scope: scope) }
        rejects("stale delete rejected") { try unbound.deleteRemote(stale, scope: scope) }
        rejects("relative path rejected") { _ = try item("bad", "../escape").validated() }
        rejects("control path rejected") { _ = try item("bad", "/bad\u{0}").validated() }
        rejects("name limit") { _ = try item(String(repeating: "x", count: 101), "/good").validated() }
        rejects("empty title") { _ = try item(" ", "/good").validated() }
        rejects("duplicate local bookmark") { try a.saveLocal(.init(title: "same", path: local.path), original: nil) }
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("{invalid".utf8).write(to: corruptURL)
        let corrupt = SFTPBookmarkStore(fileURL: corruptURL)
        rejects("corrupt store cannot overwrite") { try corrupt.save(item("bad", "/good")) }
        check(try Data(contentsOf: corruptURL) == Data("{invalid".utf8), "corrupt original preserved")
        try Data("{\"schemaVersion\":99}".utf8).write(to: corruptURL)
        let future = SFTPBookmarkStore(fileURL: corruptURL)
        check(future.loadError == BookmarkError.unsupportedVersion.localizedDescription, "future schema refused")
        var fail = false
        let failing = SFTPBookmarkStore(fileURL: root.appendingPathComponent("failure/bookmarks.json"), persist: { data,url in
            if fail { throw CocoaError(.fileWriteNoPermission) }; try SFTPBookmarkStore.writePrivateFile(data,to:url)
        })
        failing.bindScope(scope); try failing.prepareUnifiedSync(scope: scope, enabled: true)
        try failing.save(offline); fail = true
        rejects("failed local write preserves state") { try failing.delete(offline.id) }
        check(failing.bookmarks == [offline], "failed local delete not published")
        let rollback = BookmarkRemoteValue(id: offline.id, value: offline, revision: 1)
        rejects("failed merge cannot advance baseline") { try failing.mergeRemote([rollback], scope: scope, generation: failing.generation) }
        check(failing.partition.entries[0].revision == 0, "baseline unchanged on disk error")
        let duplicate = BookmarkRemoteValue(id: offline.id, value: offline, revision: 1)
        rejects("duplicate remote IDs rejected") { _ = try BookmarkSyncPolicy.merge(.init(), remote: [duplicate,duplicate]) }
        rejects("previously confirmed remote record missing rejected") { _ = try BookmarkSyncPolicy.merge(a.partition, remote: []) }
        let cancelStore = try make("cancel")
        try cancelStore.save(item("cancel", "/cancel"))
        backend.beforeWrite = { cancelStore.bindScope(other) }
        do { _ = try await sync(cancelStore); check(false, "account changed during write") }
        catch { check(true, "account changed during write refuses acknowledgment") }
        check(cancelStore.bookmarks.isEmpty, "inflight old-account response cannot populate new account")
        restored.bindScope(scope); restored.bindScope(nil, preserveOffline: true)
        check(restored.bookmarks == a.bookmarks, "transient offline restoration retains account view")
        restored.bindScope(nil)
        check(restored.bookmarks.isEmpty, "explicit signout after offline state hides remote view")
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("a/bookmarks.json").path)
        check((mode[.posixPermissions] as? NSNumber)?.intValue == 0o600, "bookmark file permissions private")
        let dirMode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("a").path)
        check((dirMode[.posixPermissions] as? NSNumber)?.intValue == 0o700, "bookmark directory permissions private")
        let full = BookmarkSyncPartition(enrolled: true, entries: (0..<500).map { n in
            let x = item("item", "/unique/\(n)"); return .init(id: x.id, value: x)
        })
        rejects("live bookmark capacity preserves source") { _ = try BookmarkSyncPolicy.merge(full, remote: [duplicate]) }
        let emptyTombstone = BookmarkSyncPartition(enrolled: true, entries: [.init(id: value.id, value: nil, baseline: value, revision: 2)])
        rejects("revision rollback refused") { _ = try BookmarkSyncPolicy.merge(emptyTombstone, remote: [.init(id: value.id, value: value, revision: 1)]) }
        let transportConfig = URLSessionConfiguration.ephemeral
        transportConfig.protocolClasses = [BookmarkURLProtocol.self]
        let transport = URLSession(configuration: transportConfig)
        defer { transport.invalidateAndCancel(); BookmarkURLProtocol.handler = nil }
        let http = FirestoreBookmarkBackend(projectID: project, session: transport)
        let fixture = try SFTPBookmarkSyncCodec.encrypt(.init(id: offline.id, value: offline, revision: 1), projectID: project, ownerUID: uid, masterKey: key, deviceID: device)
        func document(_ record: EncryptedSyncRecord) -> [String: Any] {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ["name": "projects/\(project)/databases/(default)/documents/users/\(uid)/sftpBookmarks/\(record.id.uuidString.lowercased())",
                    "updateTime": "2026-09-21T00:00:00.123456Z", "fields": [
                        "recordType": ["stringValue": "sftpBookmark"],
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
        BookmarkURLProtocol.handler = { request in
            guard request.url!.path.contains("/sftpBookmarks"), request.value(forHTTPHeaderField: "Authorization") == "Bearer test" else { throw BookmarkSyncError.invalidData }
            return (200, try JSONSerialization.data(withJSONObject: ["documents": [doc]]))
        }
        let fetched = try await http.fetch(ownerUID: uid, idToken: "test")
        check(fetched.count == 1 && fetched[0].record == fixture && fetched[0].updateTime == "2026-09-21T00:00:00.123456Z", "REST decoder preserves ciphertext and exact server precondition")
        BookmarkURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            guard request.httpMethod == "PATCH", query.contains(where: { $0.name == "currentDocument.exists" && $0.value == "false" }) else { throw BookmarkSyncError.invalidData }
            return (200, try JSONSerialization.data(withJSONObject: doc))
        }
        try await http.write(fixture, expectedUpdateTime: nil, ownerUID: uid, idToken: "test")
        check(true, "new REST record uses create-only precondition and validates response")
        let update = try SFTPBookmarkSyncCodec.encrypt(.init(id: offline.id, value: offline, revision: 2), projectID: project, ownerUID: uid, masterKey: key, deviceID: device)
        BookmarkURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            guard query.contains(where: { $0.name == "currentDocument.updateTime" && $0.value == fetched[0].updateTime }) else { throw BookmarkSyncError.invalidData }
            return (200, try JSONSerialization.data(withJSONObject: document(update)))
        }
        try await http.write(update, expectedUpdateTime: fetched[0].updateTime, ownerUID: uid, idToken: "test")
        check(true, "updates use exact updateTime instead of blind overwrite")
        BookmarkURLProtocol.handler = { _ in (412, Data()) }
        do { try await http.write(update, expectedUpdateTime: fetched[0].updateTime, ownerUID: uid, idToken: "test"); check(false, "CAS conflict") }
        catch FirestoreBookmarkBackendError.documentAlreadyExists { check(true, "REST CAS failure prevents overwrite") }
        BookmarkURLProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["documents": [doc, doc]])) }
        do { _ = try await http.fetch(ownerUID: uid, idToken: "test"); check(false, "duplicate response") }
        catch { check(true, "REST duplicate IDs rejected") }
        var foreign = doc; foreign["name"] = "projects/other/databases/(default)/documents/users/other/sftpBookmarks/\(offline.id.uuidString.lowercased())"
        BookmarkURLProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["documents": [foreign]])) }
        do { _ = try await http.fetch(ownerUID: uid, idToken: "test"); check(false, "foreign response") }
        catch { check(true, "REST foreign document path rejected") }
        BookmarkURLProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["documents": [], "nextPageToken": "repeat"])) }
        do { _ = try await http.fetch(ownerUID: uid, idToken: "test"); check(false, "pagination loop") }
        catch { check(true, "REST pagination loop bounded") }

        print("\(passed) bookmark checks passed, 0 failed")
    }
}
