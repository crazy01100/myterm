import Foundation
import CryptoKit
import Darwin

private struct TestFailure: Error { let message: String }

@MainActor private final class EditConnectionFixture: SFTPEditConnection {
    var editingTarget: SFTPConnectionTarget?
    var editingGeneration = UUID()
    var queued: [(UUID, SFTPEditSnapshot, SFTPEditRevision)] = []
    var checks: [UUID] = []
    var cancelled: [UUID] = []
    func enqueueEdit(_ id: UUID, snapshot: SFTPEditSnapshot, path: String, baseline: SFTPEditRevision) {
        queued.append((id, snapshot, baseline))
    }
    func enqueueEditCheck(_ id: UUID, path: String) { checks.append(id) }
    func cancelEditTransfers(_ id: UUID) { cancelled.append(id) }
}

@main struct SFTPEditTests {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw TestFailure(message: name) }
        passed += 1; print("PASS: \(name)")
    }
    @MainActor static func eventually(_ name: String, timeout: TimeInterval = 5,
                                     _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { try check(true, name); return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TestFailure(message: name)
    }
    static func folder(_ url: URL) throws { try SFTPEditFileMonitor.privateDirectory(url) }
    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    static func nativeClient(_ root: URL) throws -> SFTPClient {
        let client = try SFTPClient.connectForTesting(executableURL: URL(fileURLWithPath: "/usr/libexec/sftp-server"),
            arguments: ["-d", root.path], responseTimeout: 3, initializationTimeout: 3)
        client.completeInitialization(); return client
    }

    static func testClient(_ root: URL) throws {
        let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("local")
        try folder(remote); try folder(local)
        let client = try nativeClient(remote); defer { client.close() }
        let target = remote.appendingPathComponent("script.sh"), copy = local.appendingPathComponent("script.sh")
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let baseline = try client.downloadEditingCopy(at: target.path, to: copy)
        try check(try text(copy) == "original", "delivered copy matches remote baseline")
        try check((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "delivered local copy is private")
        let date = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as! Date
        try Data("external".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
        do {
            try client.uploadItem(at: copy, to: remote.path, overwrite: true, editingBaseline: baseline) { _, _ in }
            throw TestFailure(message: "same-size/mtime conflict accepted")
        } catch SFTPEditError.conflict { try check(try text(target) == "external", "same-size/mtime external modification is preserved") }
        let revised = try client.editingRevision(at: target.path)
        try Data("local saved bytes".utf8).write(to: copy)
        try client.uploadItem(at: copy, to: remote.path, overwrite: true, editingBaseline: revised) { _, _ in }
        let after = try client.editingRevision(at: target.path)
        try check(try text(target) == "local saved bytes", "safe edit publishes saved content")
        try check(after.permissions == 0o755 && after.userID == baseline.userID && after.groupID == baseline.groupID,
                  "executable mode and ownership survive atomic replacement")
        try Data("next local edit".utf8).write(to: copy)
        var changed = false
        do {
            try client.uploadItem(at: copy, to: remote.path, overwrite: true, editingBaseline: after) { bytes, _ in
                if bytes > 0 && !changed { changed = true; try! Data("concurrent writer".utf8).write(to: target) }
            }
            throw TestFailure(message: "concurrent remote writer overwritten")
        } catch SFTPEditError.conflict { try check(try text(target) == "concurrent writer", "second check detects changes during upload") }
        let beforeCancel = try client.editingRevision(at: target.path), cancellation = SFTPTransferCancellation()
        do {
            try client.uploadItem(at: copy, to: remote.path, overwrite: true, cancellation: cancellation,
                                  editingBaseline: beforeCancel) { bytes, _ in if bytes > 0 { cancellation.cancel() } }
            throw TestFailure(message: "cancelled edit committed")
        } catch SFTPConnectionError.cancelled { try check(try text(target) == "concurrent writer", "cancel preserves original remote bytes") }
        try check(try FileManager.default.contentsOfDirectory(atPath: remote.path) == ["script.sh"], "failed edits clean owned staging files")
        try FileManager.default.setAttributes([.posixPermissions: 0o4755], ofItemAtPath: target.path)
        do { _ = try client.editingRevision(at: target.path); throw TestFailure(message: "setuid file accepted") }
        catch SFTPEditError.unsupportedMetadata { try check(true, "special permissions refuse automatic editing") }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let regular = try client.editingRevision(at: target.path)
        try client.uploadItem(at: copy, to: remote.path, overwrite: true, editingBaseline: regular) { _, _ in }
        try check(try client.editingRevision(at: target.path).permissions == 0o644, "ordinary 0644 mode preserved")
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: copy)
        do { _ = try client.editingRevision(at: target.path); throw TestFailure(message: "symlink accepted") }
        catch SFTPEditError.conflict { try check(true, "remote symlink is not an editable regular file") }
        try FileManager.default.removeItem(at: target)
        do {
            try client.uploadItem(at: copy, to: remote.path, overwrite: true, editingBaseline: regular) { _, _ in }
            throw TestFailure(message: "deleted remote target recreated")
        } catch SFTPEditError.conflict { try check(true, "deleted remote target is not silently recreated") }
    }

    @MainActor static func testCoordinator(_ root: URL) async throws {
        let edits = SFTPExternalEditStore(root: root.appendingPathComponent("coordinator"))
        var host = HostProfile(); host.hostname = "fixture.invalid"; host.username = "fixture"
        let target = SFTPConnectionTarget(host: host, username: host.username)
        let id = UUID(), content = edits.directory(id).appendingPathComponent("content")
        try folder(content)
        let file = content.appendingPathComponent("fixture.txt")
        try Data("initial".utf8).write(to: file)
        let snapshot = try SFTPEditFileMonitor.capture(file, under: root.appendingPathComponent("hash"))
        let baseline = SFTPEditRevision(digest: snapshot.digest, size: snapshot.size, userID: 1, groupID: 1, permissions: 0o644)
        snapshot.remove()
        let work = try edits.register(id: id, target: target, hostName: "Fixture", path: "/fixture.txt", trust: "trusted", baseline: baseline)
        try check(edits.existing(target: target, path: work.remotePath)?.id == id, "same target reuses retained draft")
        let connection = EditConnectionFixture(); connection.editingTarget = target
        edits.resume(id, connection: connection, trust: "wrong")
        try check(connection.checks.isEmpty, "changed trust cannot resume or write")
        edits.resume(id, connection: connection, trust: "trusted")
        edits.checked(id, result: .success(baseline), generation: connection.editingGeneration)
        try Data("save one".utf8).write(to: file)
        try await eventually("in-place save reaches transfer scheduler") { connection.queued.count == 1 }
        let first = connection.queued[0].1
        edits.started(id)
        try Data("save two".utf8).write(to: file, options: .atomic)
        try await eventually("second save recorded while first upload is active") { edits.work(id)?.latestDigest != first.digest }
        try check(connection.queued.count == 1, "only one upload per file is queued at a time")
        try check(try text(first.url) == "save one", "active upload uses immutable old snapshot")
        edits.completed(id, result: .success(()), generation: connection.editingGeneration)
        try check(connection.queued.count == 2 && edits.work(id)?.state == .waiting, "old completion queues latest save instead of claiming clean")
        try check(try text(connection.queued[1].1.url) == "save two", "second upload carries newest disk bytes")
        edits.completed(id, result: .success(()), generation: connection.editingGeneration)
        try check(edits.work(id)?.hasUnsavedChanges == false, "latest completion marks matching saved revision clean")
        try Data("save two".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(900))
        try check(connection.queued.count == 2, "no upload for identical content replacement")
        edits.pause(connection: connection)
        connection.editingGeneration = UUID()
        try Data("offline saved".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(900))
        try check(connection.queued.count == 2, "disconnect prevents background save-back")
        let restored = SFTPExternalEditStore(root: edits.root)
        try check(restored.work(id)?.state == .paused && (try text(restored.localURL(work))) == "offline saved", "restart retains offline draft without enabling uploads")
        restored.resume(id, connection: connection, trust: "trusted")
        restored.checked(id, result: .success(edits.work(id)!.baseline), generation: connection.editingGeneration)
        try await eventually("explicit recovery sends offline change") { connection.queued.count == 3 }
        let published = restored.work(id)!.possiblePublished!
        restored.completed(id, result: .failure(SFTPTransferError.outcomeUnknown(destination: "/fixture.txt", temporaryPath: "/temporary")), generation: connection.editingGeneration)
        try check(restored.work(id)?.state == .unknown && FileManager.default.fileExists(atPath: file.path), "unknown rename response retains draft and pending revision")
        restored.resume(id, connection: connection, trust: "trusted")
        restored.checked(id, result: .success(published), generation: connection.editingGeneration)
        try await Task.sleep(for: .milliseconds(900))
        try check(connection.queued.count == 3 && restored.work(id)?.possiblePublished == nil, "matching remote content resolves unknown result without re-upload")
        restored.stop(id)
        try Data("after stop".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(900))
        try check(connection.queued.count == 3 && (try text(file)) == "after stop", "stop retains local saves without remote writes")
        restored.resume(id, connection: connection, trust: "trusted")
        let external = baseline.replacingContent(digest: "different remote", size: 16)
        restored.checked(id, result: .success(external), generation: connection.editingGeneration)
        try check(restored.work(id)?.state == .conflict && restored.canConfirmConflict(id), "remote conflict requires explicit choice")
        restored.acceptConflict(id)
        try await eventually("confirmed conflict schedules overwrite against reviewed revision") { connection.queued.count == 4 }
        try check(connection.queued.last?.2 == external, "overwrite cannot bypass exact remote revision check")
        restored.stop(id)
        restored.completed(id, result: .failure(SFTPConnectionError.cancelled), generation: connection.editingGeneration)
        try check(restored.work(id)?.state == .stopped, "cancel callback cannot reactivate stopped work")
        restored.pauseForQuit()
    }

    @MainActor static func testIntegratedStore(_ root: URL) async throws {
        let remote = root.appendingPathComponent("integrated-remote")
        try folder(remote)
        let file = remote.appendingPathComponent("example.txt")
        try Data("before".utf8).write(to: file)
        var host = HostProfile(); host.hostname = "fixture.invalid"; host.username = "fixture"
        let edits = SFTPExternalEditStore(root: root.appendingPathComponent("integrated-edits"))
        let store = SFTPRemoteBrowserStore(editStore: edits, editingTrust: { "fixture" })
        store.installTestConnection(try nativeClient(remote), host: host)
        store.goToPathComponent(remote.path)
        try await eventually("remote browser loads native test directory") { store.state == .connected && store.currentPath == remote.path }
        let entry = store.entries.first { $0.name == "example.txt" }!
        var prepared: Result<SFTPEditWork, Error>?
        store.prepareEditingCopy(of: entry) { prepared = $0 }
        try await eventually("browser prepares durable edit work") { prepared != nil }
        let work = try prepared!.get()
        store.resumeEdit(work.id)
        try await eventually("existing transfer queue validates original before monitoring") { edits.work(work.id)?.state == .watching }
        try Data("from editor".utf8).write(to: edits.localURL(work), options: .atomic)
        try await eventually("actual store and native SFTP return edited bytes", timeout: 8) { try text(file) == "from editor" && edits.work(work.id)?.state == .watching }
        try check(store.transferItems.contains { $0.name.hasPrefix("回存") && $0.state == .completed }, "save-back shares normal transfer history and success state")
        var renamedHost = host; renamedHost.name = "renamed fixture"
        store.validateEditingInventory([renamedHost])
        try check(store.editingTarget != nil, "presentation-only host changes keep edit target")
        store.validateEditingInventory([])
        try check(store.editingTarget == nil && edits.work(work.id)?.state == .paused, "deleted host pauses edits and prevents reuse of stale settings")
        store.disconnect()
        try Data("offline again".utf8).write(to: edits.localURL(work))
        try await Task.sleep(for: .milliseconds(900))
        try check(try text(file) == "from editor", "browser disconnect pauses writes")
        try check(FileManager.default.fileExists(atPath: edits.localURL(work).path), "browser disconnect keeps local draft")
        edits.pauseForQuit()
    }

    @MainActor static func testTrust(_ root: URL) throws {
        var host = HostProfile(); host.hostname = "host.invalid"; host.username = "tester"
        let target = SFTPConnectionTarget(host: host, username: host.username)
        let file = root.appendingPathComponent("known-hosts")
        try Data("host.invalid ssh-ed25519 dGVzdA==\n".utf8).write(to: file)
        let first = try SFTPExternalEditStore.trustDigest(target: target, files: [file])
        try Data("other.invalid ssh-ed25519 b3RoZXI=\nhost.invalid ssh-ed25519 dGVzdA== comment\n".utf8).write(to: file)
        try check(try SFTPExternalEditStore.trustDigest(target: target, files: [file]) == first, "unrelated host and comments do not invalidate trust binding")
        let salt = Data("test salt".utf8)
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.hostname.utf8), using: SymmetricKey(data: salt)))
        try Data("|1|\(salt.base64EncodedString())|\(mac.base64EncodedString()) ssh-ed25519 dGVzdA==\n".utf8).write(to: file)
        try check(try SFTPExternalEditStore.trustDigest(target: target, files: [file]) == first, "hashed OpenSSH entry matches same public key")
        try Data("host.invalid ssh-ed25519 Y2hhbmdlZA==\n".utf8).write(to: file)
        try check(try SFTPExternalEditStore.trustDigest(target: target, files: [file]) != first, "changed endpoint public key invalidates old edit binding")
    }

    @MainActor static func testMonitor(_ root: URL) async throws {
        let area = root.appendingPathComponent("monitor"), copies = root.appendingPathComponent("monitor-copies")
        try folder(area)
        let file = area.appendingPathComponent("text")
        try Data("hello".utf8).write(to: file)
        let baseline = try SFTPEditFileMonitor.capture(file, under: copies)
        let edits = SFTPExternalEditStore(root: root.appendingPathComponent("monitor-store"))
        // Use a main-actor collector: the observer itself delivers off-main.
        var received: [SFTPEditSnapshot] = []
        var failures = 0
        let monitor = try SFTPEditFileMonitor(file: file, snapshotRoot: copies, baseline: baseline.digest) { result in
            Task { @MainActor in
                switch result { case .success(let item): received.append(item); case .failure: failures += 1 }
            }
        }
        defer { monitor.stop(); baseline.remove(); received.forEach { $0.remove() } }
        try await eventually("monitor reports actual initial disk state") { received.count == 1 }
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        try Data("world".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        try await eventually("monitor detects same-size restored-mtime save") { received.count == 2 }
        try FileManager.default.removeItem(at: file)
        try await Task.sleep(for: .milliseconds(700))
        try check(received.count == 2, "missing live file is not treated as zero-byte save")
        try Data("recreated".utf8).write(to: file)
        try await eventually("monitor rebinds recreated file") { received.count == 3 }
        try FileManager.default.removeItem(at: file)
        let other = root.appendingPathComponent("not-editor-file")
        try Data("must not copy".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        try await eventually("symlink replacement produces bounded failure") { failures == 1 }
        try check(received.count == 3, "monitor never sends symlink target contents")
        monitor.stop()
        try FileManager.default.removeItem(at: file)
        try Data("regular again".utf8).write(to: file)
        let link = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: area)
        do { _ = try SFTPEditFileMonitor.capture(link.appendingPathComponent("text"), under: copies); throw TestFailure(message: "linked directory accepted") }
        catch SFTPEditError.unstableFile { try check(true, "linked parent cannot escape private work area") }
        try check(edits.works.isEmpty, "unrelated store remains untouched by monitor tests")
    }

    static func testUnsupported(_ root: URL, python: URL, peer: String) throws {
        let area = root.appendingPathComponent("unsupported-server")
        try folder(area)
        let local = area.appendingPathComponent("local.txt")
        try Data("edited".utf8).write(to: local)
        let client = try SFTPClient.connectForTesting(executableURL: python, arguments: [peer, area.path, "unsupported"])
        defer { client.close() }
        client.completeInitialization()
        let revision = SFTPEditRevision(digest: "fixture", size: 1, userID: 1, groupID: 1, permissions: 0o644)
        do {
            try client.uploadItem(at: local, to: "/", overwrite: true, editingBaseline: revision) { _, _ in }
            throw TestFailure(message: "unsupported server accepted edit")
        } catch SFTPTransferError.unsafeOverwrite { try check(true, "save-back refuses server without atomic replacement") }
    }

    @MainActor static func testPreparationQueue(_ root: URL, python: URL, peer: String) async throws {
        for phase in [SFTPPreparationPhase.download, .verification] {
            let area = root.appendingPathComponent("prepare-\(phase == .download ? "download" : "verify")")
            try folder(area)
            let source = area.appendingPathComponent("large.log"), other = area.appendingPathComponent("other.log")
            let payload = Data(repeating: 65, count: 2 * 1024 * 1024)
            try payload.write(to: source); try Data("queued".utf8).write(to: other)
            let edits = SFTPExternalEditStore(root: root.appendingPathComponent("works-\(UUID())"))
            let store = SFTPRemoteBrowserStore(editStore: edits, editingTrust: { "fixture" })
            var host = HostProfile(); host.hostname = "fixture.invalid"; host.username = "test"
            let client = try SFTPClient.connectForTesting(executableURL: python, arguments: [peer, area.path, "edit_slow"])
            client.completeInitialization(); store.installTestConnection(client, host: host)
            defer { store.disconnect() }
            let entry = SFTPDirectoryEntry(name: "large.log", longName: "", attributes: SFTPFileAttributes(size: UInt64(payload.count), permissions: 0o100644))
            var opened = 0, cancelled = 0, duplicates = 0
            store.prepareEditingCopy(of: entry) { result in
                switch result {
                case .success: opened += 1
                case .failure(let error): if case SFTPConnectionError.cancelled = error { cancelled += 1 }
                }
            }
            try check(store.transferItems.count == 1 && store.hasActiveTransfers && store.canForceStopTransfers,
                      "preparation is visible and interruptible immediately: \(phase)")
            let firstID = store.transferItems[0].id
            store.prepareEditingCopy(of: entry) { _ in duplicates += 1 }
            store.prepareTemporaryCopy(of: entry) { _ in duplicates += 1 }
            try check(store.transferItems.count == 1 && duplicates == 0 && store.errorMessage == nil,
                      "both opening paths deduplicate without false file warning: \(phase)")
            let secondStore = SFTPRemoteBrowserStore(editStore: edits, editingTrust: { "fixture" })
            let secondClient = try SFTPClient.connectForTesting(executableURL: python, arguments: [peer, area.path, "edit_slow"])
            secondClient.completeInitialization(); secondStore.installTestConnection(secondClient, host: host)
            secondStore.prepareEditingCopy(of: entry) { _ in duplicates += 1 }
            try check(secondStore.transferItems.isEmpty && duplicates == 0, "another window cannot submit duplicate preparation: \(phase)")
            secondStore.disconnect()
            let queued = SFTPDirectoryEntry(name: "other.log", longName: "", attributes: SFTPFileAttributes(size: 6, permissions: 0o100644))
            var queuedCancelled = false
            store.prepareEditingCopy(of: queued) { result in
                if case .failure(let error) = result, case SFTPConnectionError.cancelled = error { queuedCancelled = true }
            }
            try check(store.transferItems[1].state == .waiting, "another file queues behind active preparation: \(phase)")
            store.cancelTransfer(store.transferItems[1].id)
            try check(queuedCancelled && store.transferItems[1].state == .cancelled,
                      "queued preparation can cancel before download: \(phase)")
            try await eventually("live phase and byte progress reported: \(phase)") {
                store.transferItems[0].preparationPhase == phase && store.transferItems[0].completedBytes > (phase == .download ? 0 : UInt64(payload.count))
            }
            let item = store.transferItems[0]
            try check(item.totalBytes == UInt64(payload.count * 2) && (item.fractionCompleted ?? 1) < 1,
                      "combined progress includes verification and is not premature completion: \(phase)")
            store.cancelTransfer(firstID)
            try check(store.transferItems[0].state == .cancelling, "active preparation immediately shows cancelling: \(phase)")
            try await eventually("active phase cancellation finishes without opening editor: \(phase)") {
                store.transferItems[0].state == .cancelled && cancelled == 1 && opened == 0
            }
            try check(edits.works.isEmpty && !(try FileManager.default.contentsOfDirectory(atPath: edits.root.path)).contains(where: { UUID(uuidString: $0) != nil }),
                      "cancel removes only undelivered preparation and creates no editing work: \(phase)")
            try check(try Data(contentsOf: source) == payload, "preparation cancellation never modifies remote file: \(phase)")
            try await eventually("connection refresh finishes after cancel: \(phase)") { store.state == .connected }
            // installTestConnection starts at /; the peer's refresh remains at /.
            store.prepareEditingCopy(of: entry) { result in if case .success = result { opened += 1 } }
            try await eventually("cancelled target can reopen on same connection: \(phase)", timeout: 8) { opened == 1 }
            try check(edits.works.count == 1 && store.transferItems.last?.state == .completed,
                      "finished preparation is recorded only after both reads: \(phase)")
            let saved = edits.works[0]
            try check(try Data(contentsOf: edits.localURL(saved)) == payload, "delivered copy remains complete: \(phase)")
            try await eventually("directory refresh completes before busy test: \(phase)") { store.state == .connected }
            store.createDirectory(named: "busy-folder")
            var busyError: Error?
            store.prepareEditingCopy(of: entry) { if case .failure(let error) = $0 { busyError = error } }
            if case SFTPEditError.operationInProgress? = busyError {
                try check(true, "unrelated file operation reports busy rather than unstable file: \(phase)")
            } else { throw TestFailure(message: "busy error was not specific") }
            try await eventually("busy operation releases state: \(phase)") { !store.isFileOperationInProgress && store.state == .connected }
            // A preview-only download has a single pass and uses the same queue.
            var preview: URL?
            store.prepareTemporaryCopy(of: queued) { result in if case .success(let url) = result { preview = url } }
            try await eventually("local-copy-only opening finishes through visible queue: \(phase)") { preview != nil }
            try check(store.transferItems.last?.totalBytes == 6 && store.transferItems.last?.preparationPhase == .download,
                      "local-only copy does not invent verification bytes: \(phase)")
            if let preview { try FileManager.default.removeItem(at: preview.deletingLastPathComponent()) }
            try await eventually("preview refresh finishes: \(phase)") { store.state == .connected }
            var previewCancelled = false
            store.prepareTemporaryCopy(of: entry) { result in
                if case .failure(let error) = result, case SFTPConnectionError.cancelled = error { previewCancelled = true }
            }
            let previewID = store.transferItems.last!.id
            try await eventually("local-only preview exposes byte progress: \(phase)") { (store.transferItems.last?.completedBytes ?? 0) > 0 }
            store.cancelTransfer(previewID)
            try await eventually("local-only preview is cancellable too: \(phase)") { previewCancelled && store.transferItems.last?.state == .cancelled }
            try check(try Data(contentsOf: edits.localURL(saved)) == payload, "cancelling a preview preserves an already delivered draft: \(phase)")
        }

        let stalled = root.appendingPathComponent("stalled-preparation")
        try folder(stalled)
        let large = stalled.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: 4 * 1024 * 1024 * 1024); try file.close()
        let edits = SFTPExternalEditStore(root: root.appendingPathComponent("stalled-edits"))
        let store = SFTPRemoteBrowserStore(editStore: edits, editingTrust: { "fixture" })
        var host = HostProfile(); host.hostname = "stall.invalid"; host.username = "test"
        let client = try SFTPClient.connectForTesting(executableURL: python, arguments: [peer, stalled.path, "edit_stall"])
        client.completeInitialization(); store.installTestConnection(client, host: host)
        let entry = SFTPDirectoryEntry(name: "huge.log", longName: "", attributes: SFTPFileAttributes(size: 4 * 1024 * 1024 * 1024, permissions: 0o100644))
        var callbacks = 0
        store.prepareEditingCopy(of: entry) { _ in callbacks += 1 }
        try await eventually("stalled multi-gigabyte preparation advertises its phase") { store.transferItems.first?.preparationPhase == .download }
        store.cancelTransfer(store.transferItems[0].id)
        try check(store.canForceStopTransfers && store.transferItems[0].state == .cancelling, "blocked request retains force-disconnect action")
        let started = Date()
        store.disconnect()
        try await eventually("force disconnect ends stalled read within bound", timeout: 3) { store.transferItems[0].state.isFinished }
        try check(Date().timeIntervalSince(started) < 3 && callbacks == 0 && edits.works.isEmpty,
                  "late disconnected preparation cannot launch editor or create work")
        try check(!edits.isPreparing(target: SFTPConnectionTarget(host: host, username: host.username), path: "/huge.log"),
                  "disconnect releases preparation reservation")
    }

    @MainActor static func testCacheLifecycle(_ root: URL) async throws {
        let edits = SFTPExternalEditStore(root: root.appendingPathComponent("cleanup-edits"))
        var host = HostProfile(); host.hostname = "cleanup.invalid"; host.username = "fixture"
        let target = SFTPConnectionTarget(host: host, username: host.username)
        let connection = EditConnectionFixture(); connection.editingTarget = target
        let other = EditConnectionFixture(); other.editingTarget = target
        func make(_ name: String, owner: SFTPEditConnection? = nil) throws -> SFTPEditWork {
            let id = UUID(), bytes = Data("baseline".utf8)
            let area = edits.directory(id).appendingPathComponent("content")
            try folder(area); try bytes.write(to: area.appendingPathComponent(name))
            let revision = SFTPEditRevision(digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                size: UInt64(bytes.count), userID: 1, groupID: 1, permissions: 0o644)
            return try edits.register(id: id, target: target, hostName: "Fixture", path: "/" + name,
                trust: "fixture", baseline: revision, connection: owner)
        }
        let clean = try make("clean.txt", owner: connection)
        let dirty = try make("dirty.txt", owner: connection)
        let unrelated = try make("other.txt", owner: other)
        let legacy = try make("legacy.txt")
        let date = try FileManager.default.attributesOfItem(atPath: edits.localURL(dirty).path)[.modificationDate] as! Date
        try Data("new data".utf8).write(to: edits.localURL(dirty))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: edits.localURL(dirty).path)
        let end = edits.beginEnding(connection: connection), token = SFTPTransferCancellation()
        let issues = await edits.inspectEnding(end, connection: connection, cancellation: token) { _ in }
        try check(issues.map(\.id) == [dirty.id], "last disk scan detects same-size/mtime save without a monitor event")
        try check(FileManager.default.fileExists(atPath: edits.localURL(clean).path), "inspection does not delete a clean copy before aggregate decision")
        let failures = await edits.cleanEnding(end, connection: connection, excluding: [dirty.id], cancellation: token) { _ in }
        try check(failures.isEmpty && edits.work(clean.id) == nil && !FileManager.default.fileExists(atPath: edits.directory(clean.id).path), "mixed close removes only independently verified clean job")
        try check(edits.preserveEnding(end, connection: connection), "unfinished job recovery metadata is persisted before disconnect")
        edits.pause(connection: connection)
        try check(try text(edits.localURL(dirty)) == "new data", "dirty draft survives preserve-and-close")
        try check(edits.work(unrelated.id) != nil && edits.work(legacy.id) != nil, "other connection and old unbound job are outside cleanup scope")
        let recovered = SFTPExternalEditStore(root: edits.root)
        try check(recovered.work(dirty.id)?.state == .paused && recovered.existing(target: target, path: dirty.remotePath)?.id == dirty.id,
                  "restart keeps original draft and prevents a replacement download")

        let late = try make("late.txt", owner: connection)
        let lateEnd = edits.beginEnding(connection: connection)
        try check(await edits.inspectEnding(lateEnd, connection: connection, cancellation: token) { _ in }.isEmpty, "unchanged fresh copy passes stable inspection")
        try Data("new data".utf8).write(to: edits.localURL(late), options: .atomic)
        let lateIssues = await edits.cleanEnding(lateEnd, connection: connection, excluding: [], cancellation: token) { _ in }
        try check(lateIssues.map(\.id) == [late.id] && (try text(edits.localURL(late))) == "new data", "save after inspection is checked again before deletion")
        edits.cancelEnding(lateEnd, connection: connection); edits.pause(connection: connection)

        let stale = try make("stale.txt", owner: connection)
        let staleEnd = edits.beginEnding(connection: connection)
        connection.editingGeneration = UUID()
        _ = await edits.cleanEnding(staleEnd, connection: connection, excluding: [], cancellation: token) { _ in }
        try check(FileManager.default.fileExists(atPath: edits.localURL(stale).path), "old generation cannot clean after reconnect")
        edits.pause(connection: connection)
        let cancelled = try make("cancelled.txt", owner: connection)
        let cancelEnd = edits.beginEnding(connection: connection), cancelledToken = SFTPTransferCancellation()
        cancelledToken.cancel()
        _ = await edits.cleanEnding(cancelEnd, connection: connection, excluding: [], cancellation: cancelledToken) { _ in }
        try check(FileManager.default.fileExists(atPath: edits.localURL(cancelled).path), "cancelling close verification preserves cache")
        edits.cancelEnding(cancelEnd, connection: connection); edits.pause(connection: connection)

        let symbolic = try make("symbolic.txt", owner: connection)
        let outside = root.appendingPathComponent("not-a-cache.txt")
        try Data("must remain".utf8).write(to: outside)
        try FileManager.default.removeItem(at: edits.localURL(symbolic))
        try FileManager.default.createSymbolicLink(at: edits.localURL(symbolic), withDestinationURL: outside)
        let symlinkEnd = edits.beginEnding(connection: connection)
        let symlinkIssues = await edits.cleanEnding(symlinkEnd, connection: connection, excluding: [], cancellation: token) { _ in }
        try check(symlinkIssues.count == 1 && (try text(outside)) == "must remain", "content symlink refuses cleanup and preserves external target")
        edits.pause(connection: connection)

        let changing = try make("changing.txt", owner: connection)
        let changingFile = edits.localURL(changing)
        let writer = Task {
            try await Task.sleep(for: .milliseconds(100))
            try Data("new data".utf8).write(to: changingFile, options: .atomic)
        }
        let changingEnd = edits.beginEnding(connection: connection)
        let changingIssues = await edits.inspectEnding(changingEnd, connection: connection, cancellation: token) { _ in }
        try await writer.value
        try check(changingIssues.count == 1 && (try text(changingFile)) == "new data", "save during stability interval refuses cleanup")
        edits.pause(connection: connection)

        let noJournal = try make("journal.txt", owner: connection)
        let journal = edits.directory(noJournal.id).appendingPathComponent("work.json")
        let journalData = try Data(contentsOf: journal)
        try FileManager.default.removeItem(at: journal); try folder(journal)
        let noJournalEnd = edits.beginEnding(connection: connection)
        let journalIssues = await edits.cleanEnding(noJournalEnd, connection: connection, excluding: [], cancellation: token) { _ in }
        try check(journalIssues.count == 1 && (try text(edits.localURL(noJournal))) == "baseline", "cannot delete content when cleanup journal cannot be persisted")
        try check(!edits.preserveEnding(noJournalEnd, connection: connection), "preservation failure is reported rather than claiming safe close")
        try FileManager.default.removeItem(at: journal); try journalData.write(to: journal)
        edits.pause(connection: connection)

        let interrupted = try make("interrupted.txt", owner: connection)
        let snapshots = edits.directory(interrupted.id).appendingPathComponent("snapshots")
        try folder(snapshots)
        let invalid = snapshots.appendingPathComponent("invalid-link")
        try FileManager.default.createSymbolicLink(at: invalid, withDestinationURL: outside)
        let interruptedEnd = edits.beginEnding(connection: connection)
        let cleanupIssues = await edits.cleanEnding(interruptedEnd, connection: connection, excluding: [], cancellation: token) { _ in }
        try check(cleanupIssues.count == 1 && edits.work(interrupted.id)?.cleanupStarted == true, "partial filesystem cleanup retains journal and visible retry state")
        try check(try text(outside) == "must remain", "snapshot cleanup never follows symlinks")
        edits.pause(connection: connection)
        let restarted = SFTPExternalEditStore(root: edits.root)
        try check(restarted.work(interrupted.id)?.state == .cleanup, "restart recognizes interrupted cleanup without deleting anything")
        try check(FileManager.default.fileExists(atPath: edits.directory(interrupted.id).appendingPathComponent("work.json").path), "manifest outlives removed clean content during interrupted cleanup")
        try FileManager.default.removeItem(at: invalid)
        restarted.retryCleanup(interrupted.id)
        try await eventually("explicit retry completes journal after content was already removed") { restarted.work(interrupted.id) == nil }
        try check(!FileManager.default.fileExists(atPath: edits.directory(interrupted.id).path), "retry removes only the interrupted owned directory")

        let queued = try make("queued.txt", owner: connection)
        edits.resume(queued.id, connection: connection, trust: "fixture")
        edits.checked(queued.id, result: .success(queued.baseline), generation: connection.editingGeneration)
        try Data("saved change".utf8).write(to: edits.localURL(queued))
        try await eventually("save queued before close") { connection.queued.contains { $0.0 == queued.id } }
        let busyEnd = edits.beginEnding(connection: connection)
        try check(await edits.inspectEnding(busyEnd, connection: connection, cancellation: token) { _ in }.contains { $0.id == queued.id }, "queued upload cannot qualify as clean")
        edits.completed(queued.id, result: .failure(SFTPTransferError.outcomeUnknown(destination: "/queued.txt", temporaryPath: "/stage")), generation: connection.editingGeneration)
        try check(edits.preserveEnding(busyEnd, connection: connection), "unknown publication is persisted before close")
        edits.pause(connection: connection)
        let uncertain = SFTPExternalEditStore(root: edits.root)
        try check(uncertain.work(queued.id)?.possiblePublished != nil && FileManager.default.fileExists(atPath: edits.localURL(queued).path), "unknown outcome survives restart for remote reconciliation")
        let failed = try make("failed.txt", owner: connection)
        edits.resume(failed.id, connection: connection, trust: "fixture")
        edits.checked(failed.id, result: .failure(SFTPEditError.conflict), generation: connection.editingGeneration)
        let failedEnd = edits.beginEnding(connection: connection)
        try check(await edits.inspectEnding(failedEnd, connection: connection, cancellation: token) { _ in }.count == 1, "conflict keeps even an unchanged disk copy")
        edits.cancelEnding(failedEnd, connection: connection); edits.pause(connection: connection)

        let monitoring = try make("monitoring.txt", owner: connection)
        edits.resume(monitoring.id, connection: connection, trust: "fixture")
        edits.checked(monitoring.id, result: .success(monitoring.baseline), generation: connection.editingGeneration)
        let back = edits.beginEnding(connection: connection)
        try Data("return and save".utf8).write(to: edits.localURL(monitoring))
        edits.cancelEnding(back, connection: connection)
        try await eventually("return from close prompt resumes monitoring and pending disk saves") { connection.queued.contains { $0.0 == monitoring.id } }
        edits.completed(monitoring.id, result: .success(()), generation: connection.editingGeneration)
        edits.stop(monitoring.id)
        try check(FileManager.default.fileExists(atPath: edits.localURL(monitoring).path), "stop-save-back alone never cleans content")
        edits.pauseForQuit()
        try check(FileManager.default.fileExists(atPath: edits.localURL(monitoring).path), "normal quit retains drafts without explicit close")
        edits.pause(connection: connection)
    }

    @MainActor static func testEndIntegration(_ root: URL) async throws {
        let remote = root.appendingPathComponent("close-remote"); try folder(remote)
        let file = remote.appendingPathComponent("file.txt"); try Data("original".utf8).write(to: file)
        let edits = SFTPExternalEditStore(root: root.appendingPathComponent("close-edits"))
        let store = SFTPRemoteBrowserStore(editStore: edits, editingTrust: { "fixture" })
        var host = HostProfile(); host.hostname = "close.invalid"; host.username = "fixture"
        func connectAndOpen() async throws -> SFTPEditWork {
            store.installTestConnection(try nativeClient(remote), host: host)
            store.goToPathComponent(remote.path)
            try await eventually("close fixture connected") { store.currentPath == remote.path && store.state == .connected }
            var result: Result<SFTPEditWork, Error>?
            store.prepareEditingCopy(of: store.entries[0]) { result = $0 }
            try await eventually("close fixture prepared") { result != nil && store.state == .connected && !store.hasActiveTransfers }
            return try result!.get()
        }
        let first = try await connectAndOpen()
        var closed = false
        store.requestEnd { closed = true }
        try check(store.endingStatus != nil, "explicit close exposes verification status")
        try await eventually("clean close automatically ends connection without confirmation") { closed && store.state == .disconnected }
        try check(edits.work(first.id) == nil && (try text(file)) == "original", "real store removes initial unmodified cache without changing remote")
        edits.completed(first.id, result: .success(()), generation: store.editingGeneration)
        try check(edits.work(first.id) == nil, "late completion cannot resurrect a cleaned job")
        try Data("remote newest".utf8).write(to: file)
        let second = try await connectAndOpen()
        try check(second.id != first.id && (try text(edits.localURL(second))) == "remote newest", "next opening downloads latest remote bytes as a new job")
        try Data("local new draft".utf8).write(to: edits.localURL(second))
        closed = false; store.requestEnd { closed = true }
        try await eventually("dirty close prompts once") { store.endingStatus?.checking == false }
        try check(!closed && store.state == .connected && store.endingStatus?.issues.count == 1, "prompt keeps original connection and draft")
        store.preserveAndEnd()
        try await eventually("preserve decision closes connection") { closed && store.state == .disconnected }
        try check(try text(edits.localURL(second)) == "local new draft", "real close preserves dirty bytes for explicit recovery")
        let third = try await connectAndOpen()
        try check(third.id == second.id && (try text(edits.localURL(third))) == "local new draft", "reopen does not overwrite disconnected draft")
        store.disconnect()
        edits.pauseForQuit()
        // A host selected for switching may disappear while the close pass runs.
        store.installTestConnection(try nativeClient(remote), host: host)
        store.validateEditingInventory([host])
        var removed = HostProfile(); removed.hostname = "removed.invalid"; removed.username = "fixture"
        store.requestSwitch(to: removed, username: removed.username)
        try await eventually("host switch closes old connection then refuses stale inventory") { store.endingStatus == nil && store.state == .disconnected && store.errorMessage != nil }
        try check(store.connectedHost == nil && edits.work(second.id) != nil, "stale host switch opens no connection and leaves unbound draft alone")
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: "/private/tmp/MyTerm-SFTP-edit-\(UUID())", isDirectory: true)
        try folder(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await testCacheLifecycle(root)
        try await testEndIntegration(root)
        try testClient(root)
        try await testCoordinator(root)
        try await testIntegratedStore(root)
        try await testMonitor(root)
        try testTrust(root)
        try testUnsupported(root, python: URL(fileURLWithPath: CommandLine.arguments[1]), peer: CommandLine.arguments[2])
        try await testPreparationQueue(root, python: URL(fileURLWithPath: CommandLine.arguments[1]), peer: CommandLine.arguments[2])
        print("\(passed) SFTP editing checks passed, 0 failed")
    }
}
