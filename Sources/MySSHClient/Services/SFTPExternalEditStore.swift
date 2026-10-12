import Combine
import CryptoKit
import Foundation
import Darwin

@MainActor protocol SFTPEditConnection: AnyObject {
    var editingTarget: SFTPConnectionTarget? { get }
    var editingGeneration: UUID { get }
    func enqueueEdit(_ id: UUID, snapshot: SFTPEditSnapshot, path: String, baseline: SFTPEditRevision)
    func enqueueEditCheck(_ id: UUID, path: String)
    func cancelEditTransfers(_ id: UUID)
}

struct SFTPEditWork: Identifiable, Codable {
    var schemaVersion = 1
    enum State: String, Codable {
        case paused, watching, waiting, uploading, failed, conflict, unknown, stopped, cleanup
        var title: String {
            switch self {
            case .cleanup: "清理待完成"
            case .paused: "已暫停"
            case .watching: "監看中"
            case .waiting: "等待回存"
            case .uploading: "回存中"
            case .failed: "回存失敗"
            case .conflict: "需確認"
            case .unknown: "結果待確認"
            case .stopped: "已停止回存"
            }
        }
    }
    let id: UUID
    let target: SFTPConnectionTarget
    let hostName: String
    let remotePath: String
    let trustDigest: String
    var baseline: SFTPEditRevision
    var latestDigest: String
    var possiblePublished: SFTPEditRevision?
    var state: State
    var message: String?
    var cleanupStarted: Bool?
    var name: String { (remotePath as NSString).lastPathComponent }
    var hasUnsavedChanges: Bool { latestDigest != baseline.digest || possiblePublished != nil }
    var targetDescription: String { "\(hostName) · \(target.username)@\(target.hostname):\(target.port)" }
}

/// Shared across windows, but each live edit is bound to exactly one existing
/// SFTP connection/generation. Retains drafts, never credentials or connections.
@MainActor final class SFTPExternalEditStore: ObservableObject {
    static let shared = SFTPExternalEditStore(root: AppPaths.sftpEditsDirectory)
    @Published private(set) var works: [SFTPEditWork] = []
    @Published var errorMessage: String?
    @Published var conflictID: UUID?
    let root: URL

    private final class Runtime {
        weak var connection: SFTPEditConnection?
        var generation: UUID?
        var monitor: SFTPEditFileMonitor?
        var monitorID = UUID()
        var latest: SFTPEditSnapshot?
        var active: SFTPEditSnapshot?
        var checking = false
        var conflict: SFTPEditRevision?
        var ending: UUID?
        var restartMonitor = false
        var cleanupInProgress = false
        deinit { monitor?.stop(); latest?.remove(); active?.remove() }
    }
    private var runtime: [UUID: Runtime] = [:]
    private var preparing: [(UUID, SFTPConnectionTarget, String)] = []

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: self.root.path) else { return }
        do {
            for directory in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: directory.lastPathComponent),
                      directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { continue }
                let manifest = directory.appendingPathComponent("work.json")
                // An interrupted preparation has not delivered a file to an editor.
                // Retain its directory without preventing other jobs from loading.
                guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
                do {
                    let data = try Data(contentsOf: manifest)
                    guard data.count <= 1024 * 1024 else { throw SFTPEditError.unstableFile }
                    var work = try JSONDecoder().decode(SFTPEditWork.self, from: data)
                    guard work.schemaVersion == 1, work.id == id, Self.validPath(work.remotePath) else { throw SFTPEditError.unstableFile }
                    if work.cleanupStarted == true {
                        work.state = .cleanup; work.message = "上次快取清理未完成，可重試清理；尚存檔案仍保留。"
                    } else if work.state != .stopped { work.state = .paused; work.message = "重新連線到原主機後，可選擇恢復回存。" }
                    works.append(work)
                } catch { errorMessage = "部分編輯工作的狀態無法讀取；其他工作已載入，原始副本仍保留在 SFTP Edits。" }
            }
            works.sort { $0.remotePath < $1.remotePath }
        } catch { errorMessage = "部分編輯工作無法讀取；本機副本仍保留在 SFTP Edits。\(error.localizedDescription)" }
    }

    func work(_ id: UUID) -> SFTPEditWork? { works.first { $0.id == id } }
    func existing(target: SFTPConnectionTarget, path: String) -> SFTPEditWork? {
        works.first { $0.target == target && $0.remotePath == path }
    }
    func reserve(_ id: UUID, target: SFTPConnectionTarget, path: String) -> Bool {
        guard !preparing.contains(where: { $0.1 == target && $0.2 == path }) else { return false }
        preparing.append((id, target, path)); return true
    }
    func isPreparing(target: SFTPConnectionTarget, path: String) -> Bool {
        preparing.contains { $0.1 == target && $0.2 == path }
    }
    func releasePreparation(_ id: UUID) { preparing.removeAll { $0.0 == id } }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func localURL(_ work: SFTPEditWork) -> URL {
        directory(work.id).appendingPathComponent("content", isDirectory: true).appendingPathComponent(work.name)
    }
    private func snapshots(_ id: UUID) -> URL { directory(id).appendingPathComponent("snapshots", isDirectory: true) }
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && !path.hasSuffix("/") &&
            !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    /// Bind to this endpoint's trusted public keys, including OpenSSH hashed
    /// hostnames. Unrelated host additions must not invalidate saved drafts.
    static func trustDigest(target: SFTPConnectionTarget,
                            files: [URL] = [AppPaths.knownHostsFile, AppPaths.importedKnownHostsRawFile]) throws -> String {
        let hostname = target.hostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let endpoint = target.port == 22 ? hostname : "[\(hostname)]:\(target.port)"
        var keys = Set<String>()
        for file in files {
            let data = try Data(contentsOf: file)
            guard data.count <= 10 * 1024 * 1024 else { throw SFTPEditError.differentConnection }
            guard let text = String(data: data, encoding: .utf8) else { throw SFTPEditError.differentConnection }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let first = fields.first, !first.hasPrefix("#") else { continue }
                let offset = first.hasPrefix("@") ? 1 : 0
                guard fields.count >= offset + 3 else { continue }
                let host = fields[offset]
                let matches: Bool
                if host.hasPrefix("|1|") {
                    let parts = host.split(separator: "|", omittingEmptySubsequences: false)
                    if parts.count == 4, let salt = Data(base64Encoded: String(parts[2])),
                       let expected = Data(base64Encoded: String(parts[3])) {
                        matches = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(endpoint.utf8), using: SymmetricKey(data: salt))) == expected
                    } else { matches = false }
                } else {
                    let patterns = host.lowercased().split(separator: ",").map(String.init)
                    // Bracketed IPv6/port literals are checked before wildcard matching.
                    let match: (String) -> Bool = { $0 == endpoint || fnmatch($0, endpoint, 0) == 0 }
                    matches = patterns.contains { !$0.hasPrefix("!") && match($0) } &&
                        !patterns.contains { $0.hasPrefix("!") && match(String($0.dropFirst())) }
                }
                if matches { keys.insert((offset == 1 ? fields[0] + " " : "") + fields[offset + 1] + " " + fields[offset + 2]) }
            }
        }
        guard !keys.isEmpty else { throw SFTPEditError.differentConnection }
        return SHA256.hash(data: Data(keys.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func register(id: UUID, target: SFTPConnectionTarget, hostName: String, path: String,
                  trust: String, baseline: SFTPEditRevision, connection: SFTPEditConnection? = nil) throws -> SFTPEditWork {
        guard Self.validPath(path) else { throw SFTPFileOperationError.unsafeName(path) }
        let work = SFTPEditWork(id: id, target: target, hostName: hostName, remotePath: path,
            trustDigest: trust, baseline: baseline, latestDigest: baseline.digest, state: .paused)
        try persist(work)
        works.append(work)
        if let connection {
            let run = Runtime(); run.connection = connection; run.generation = connection.editingGeneration
            runtime[id] = run
        }
        return work
    }

    private func persist(_ work: SFTPEditWork) throws {
        try SFTPEditFileMonitor.privateDirectory(root)
        try SFTPEditFileMonitor.privateDirectory(directory(work.id))
        let url = directory(work.id).appendingPathComponent("work.json")
        try JSONEncoder().encode(work).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult private func update(_ id: UUID, _ change: (inout SFTPEditWork) -> Void) -> Bool {
        guard let index = works.firstIndex(where: { $0.id == id }) else { return false }
        change(&works[index])
        do { try persist(works[index]); return true }
        catch {
            works[index].state = .failed
            works[index].message = "無法保存編輯狀態，已停止自動回存；本機副本保留。"
            return false
        }
    }

    /// Called only after successfully opening the editor, or explicit Resume.
    func resume(_ id: UUID, connection: SFTPEditConnection, trust: String) {
        guard let work = work(id), connection.editingTarget == work.target, trust == work.trustDigest else {
            errorMessage = SFTPEditError.differentConnection.localizedDescription; return
        }
        let run = runtime[id] ?? Runtime(); runtime[id] = run
        guard !run.checking, run.active == nil, run.ending == nil, work.cleanupStarted != true else { return }
        run.connection = connection; run.generation = connection.editingGeneration
        run.checking = true; run.conflict = nil
        run.monitor?.stop(); run.monitor = nil; run.monitorID = UUID()
        guard update(id, { $0.state = .paused; $0.message = "正在確認遠端檔案…" }) else { run.checking = false; return }
        connection.enqueueEditCheck(id, path: work.remotePath)
    }

    func checked(_ id: UUID, result: Result<SFTPEditRevision, Error>, generation: UUID) {
        guard let run = runtime[id], run.generation == generation, let work = work(id),
              run.connection?.editingGeneration == generation else { return }
        run.checking = false
        switch result {
        case .failure(let error): fail(id, error)
        case .success(let revision):
            if revision != work.baseline && revision != work.possiblePublished {
                run.conflict = revision
                update(id) { $0.state = .conflict; $0.message = SFTPEditError.conflict.localizedDescription }
                return
            }
            guard update(id, { $0.baseline = revision; $0.possiblePublished = nil; $0.state = .watching; $0.message = nil }) else { return }
            startMonitor(id)
        }
    }

    func canConfirmConflict(_ id: UUID) -> Bool { runtime[id]?.conflict != nil && runtime[id]?.ending == nil }
    func acceptConflict(_ id: UUID) {
        guard let run = runtime[id], run.ending == nil, let revision = run.conflict,
              run.connection?.editingGeneration == run.generation else { return }
        run.conflict = nil
        guard update(id, { $0.baseline = revision; $0.possiblePublished = nil; $0.state = .watching; $0.message = nil }) else { return }
        startMonitor(id) // fresh snapshot; upload still checks this exact revision twice
    }

    private func startMonitor(_ id: UUID) {
        guard let work = work(id), let run = runtime[id] else { return }
        if run.ending != nil { run.restartMonitor = true; return }
        run.monitor?.stop(); run.monitor = nil; run.latest?.remove(); run.latest = nil
        let monitorID = UUID(); run.monitorID = monitorID
        do {
            run.monitor = try SFTPEditFileMonitor(file: localURL(work), snapshotRoot: snapshots(id), baseline: work.baseline.digest) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, let current = runtime[id], current.monitorID == monitorID else {
                        if case .success(let snapshot) = result { snapshot.remove() }
                        return
                    }
                    switch result {
                    case .success(let snapshot):
                        current.latest?.remove(); current.latest = snapshot
                        if update(id, { $0.latestDigest = snapshot.digest }) { schedule(id) }
                    case .failure(let error): fail(id, error)
                    }
                }
            }
        } catch { fail(id, error) }
    }

    private func schedule(_ id: UUID) {
        guard let work = work(id), let run = runtime[id], let latest = run.latest,
              run.active == nil, !run.checking, run.ending == nil,
              [.watching, .waiting, .uploading].contains(work.state),
              let connection = run.connection, connection.editingGeneration == run.generation,
              connection.editingTarget == work.target else { return }
        if latest.digest == work.baseline.digest {
            latest.remove(); run.latest = nil
            update(id) { $0.state = .watching; $0.possiblePublished = nil }; return
        }
        guard update(id, { $0.state = .waiting; $0.possiblePublished = work.baseline.replacingContent(digest: latest.digest, size: latest.size) }) else { return }
        run.active = latest; run.latest = nil
        connection.enqueueEdit(id, snapshot: latest, path: work.remotePath, baseline: work.baseline)
    }

    func started(_ id: UUID) { update(id) { $0.state = .uploading } }

    func completed(_ id: UUID, result: Result<Void, Error>, generation: UUID) {
        guard let run = runtime[id], run.generation == generation, let work = work(id) else { return }
        let active = run.active; run.active = nil
        defer { active?.remove() }
        switch result {
        case .failure(let error): fail(id, error)
        case .success:
            guard let published = work.possiblePublished else { return }
            guard update(id, {
                $0.baseline = published; $0.possiblePublished = nil
                // Stop may have been requested while publication was committing.
                if $0.state != .stopped && $0.state != .paused { $0.state = .watching }
                $0.message = nil
            }) else { return }
            schedule(id)
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        update(id) {
            if $0.state == .stopped { return }
            $0.state = error is SFTPEditError ? .conflict : .failed
            if case SFTPTransferError.outcomeUnknown = error { $0.state = .unknown }
            $0.message = error.localizedDescription
        }
    }

    func pause(connection: SFTPEditConnection) {
        for id in Array(runtime.keys) {
            guard let run = runtime[id], run.connection === connection else { continue }
            run.monitor?.stop(); run.monitor = nil; run.monitorID = UUID()
            run.connection = nil; run.checking = false; run.ending = nil; run.restartMonitor = false
            // The retained possiblePublished revision allows a later reconnect
            // to resolve a lost rename response without blindly uploading again.
            if work(id)?.cleanupStarted != true {
                update(id) { if $0.state != .stopped { $0.state = .paused; $0.message = "連線已中斷；本機副本保留，請重連後恢復回存。" } }
            }
        }
    }

    func stop(_ id: UUID) {
        guard runtime[id]?.ending == nil, work(id)?.cleanupStarted != true else { return }
        guard let run = runtime[id] else { update(id) { $0.state = .stopped }; return }
        run.monitor?.stop(); run.monitor = nil; run.monitorID = UUID()
        update(id) { $0.state = .stopped; $0.message = "本機副本已保留，後續儲存不會回傳。" }
        run.connection?.cancelEditTransfers(id)
        run.latest?.remove(); run.latest = nil
    }

    struct Ending {
        let id = UUID()
        let generation: UUID
        let target: SFTPConnectionTarget?
        let ids: [UUID]
    }
    struct EndIssue: Identifiable {
        let id: UUID
        let name: String
        let reason: String
    }

    func beginEnding(connection: SFTPEditConnection) -> Ending {
        let ids = works.compactMap { work -> UUID? in
            guard let run = runtime[work.id], run.connection === connection,
                  run.generation == connection.editingGeneration else { return nil }
            return work.id
        }
        let end = Ending(generation: connection.editingGeneration, target: connection.editingTarget, ids: ids)
        for id in ids {
            guard let run = runtime[id] else { continue }
            run.ending = end.id; run.restartMonitor = run.monitor != nil
            run.monitor?.stop(); run.monitor = nil; run.monitorID = UUID()
        }
        return end
    }

    func cancelEnding(_ end: Ending, connection: SFTPEditConnection) {
        for id in end.ids {
            guard let run = runtime[id], run.ending == end.id else { continue }
            run.ending = nil
            if run.restartMonitor && run.connection === connection && run.generation == connection.editingGeneration,
               let work = work(id), work.cleanupStarted != true, work.state == .watching || work.state == .waiting || work.state == .uploading {
                run.restartMonitor = false
                startMonitor(id)
            }
        }
    }

    private func endWork(_ id: UUID, end: Ending, connection: SFTPEditConnection) -> SFTPEditWork? {
        guard let run = runtime[id], run.ending == end.id, run.connection === connection,
              connection.editingGeneration == end.generation, connection.editingTarget == end.target,
              let work = work(id), work.target == end.target else { return nil }
        return work
    }

    private func canClean(_ work: SFTPEditWork) -> Bool {
        guard let run = runtime[work.id], run.active == nil, !run.checking,
              work.possiblePublished == nil, ![.waiting, .uploading, .failed, .conflict, .unknown, .cleanup].contains(work.state) else { return false }
        return !run.cleanupInProgress
    }

    /// This pass never deletes anything. A second pass checks content again at
    /// publication of the cleanup decision, including saves while a prompt is up.
    func inspectEnding(_ end: Ending, connection: SFTPEditConnection, cancellation: SFTPTransferCancellation,
                       progress: (String) -> Void) async -> [EndIssue] {
        var issues: [EndIssue] = []
        for id in end.ids {
            guard let work = endWork(id, end: end, connection: connection) else { continue }
            progress(work.name)
            do {
                try cancellation.check()
                guard canClean(work) else { throw SFTPEditError.operationInProgress }
                let file = localURL(work)
                _ = try await Task.detached(priority: .utility) {
                    try await SFTPEditCacheCleanup.stable(file: file, baseline: work.baseline, cancellation: cancellation)
                }.value
                guard let latest = endWork(id, end: end, connection: connection), canClean(latest), latest.baseline == work.baseline else {
                    throw SFTPEditError.operationInProgress
                }
            } catch {
                issues.append(EndIssue(id: id, name: work.name, reason: canClean(work) ? "本機內容尚未回存、仍在變更或無法核對" : "回存尚未完成或結果需確認"))
            }
        }
        return issues
    }

    func cleanEnding(_ end: Ending, connection: SFTPEditConnection, excluding: Set<UUID>,
                     cancellation: SFTPTransferCancellation, progress: (String) -> Void) async -> [EndIssue] {
        var issues: [EndIssue] = []
        for id in end.ids where !excluding.contains(id) {
            guard let work = endWork(id, end: end, connection: connection) else { continue }
            progress(work.name)
            do {
                try cancellation.check()
                guard canClean(work) else { throw SFTPEditError.operationInProgress }
                let file = localURL(work)
                let fingerprint = try await Task.detached(priority: .utility) {
                    try await SFTPEditCacheCleanup.stable(file: file, baseline: work.baseline, cancellation: cancellation)
                }.value
                try cancellation.check()
                guard let latest = endWork(id, end: end, connection: connection), canClean(latest), latest.baseline == work.baseline else {
                    throw SFTPEditError.differentConnection
                }
                guard update(id, { $0.cleanupStarted = true; $0.state = .cleanup; $0.message = "正在清理已完成的快取。" }) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let root = self.root
                runtime[id]?.cleanupInProgress = true
                try await Task.detached(priority: .utility) {
                    try SFTPEditCacheCleanup.remove(root: root, id: id, name: work.name, fingerprint: fingerprint, cancellation: cancellation)
                }.value
                runtime.removeValue(forKey: id); works.removeAll { $0.id == id }
            } catch {
                runtime[id]?.cleanupInProgress = false
                if self.work(id)?.cleanupStarted == true {
                    update(id) { $0.state = .cleanup; $0.message = "快取清理未完成；尚存檔案保留，可重試清理。" }
                }
                issues.append(EndIssue(id: id, name: work.name, reason: "最後核對或清理未完成；尚存檔案已保留"))
            }
        }
        return issues
    }

    /// Persist before closing, even for work that was active when the prompt
    /// appeared. possiblePublished remains intact until a reconnect verifies it.
    func preserveEnding(_ end: Ending, connection: SFTPEditConnection) -> Bool {
        var saved = true
        for id in end.ids {
            guard endWork(id, end: end, connection: connection) != nil else { continue }
            if !update(id, { work in
                if work.cleanupStarted != true && work.state != .stopped { work.state = .paused }
                work.message = "連線已結束；尚存副本保留，恢復前會重新核對遠端。"
            }) { saved = false }
        }
        return saved
    }

    func retryCleanup(_ id: UUID) {
        guard let work = work(id), work.cleanupStarted == true, runtime[id]?.ending == nil, runtime[id]?.cleanupInProgress != true else { return }
        let run = runtime[id] ?? Runtime(); runtime[id] = run
        let lock = UUID(); run.ending = lock; run.cleanupInProgress = true
        let file = localURL(work), root = self.root
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    let cancellation = SFTPTransferCancellation()
                    var attributes = stat()
                    let fingerprint: SFTPEditCacheCleanup.Fingerprint?
                    if lstat(file.path, &attributes) == 0 {
                        fingerprint = try await SFTPEditCacheCleanup.stable(file: file, baseline: work.baseline, cancellation: cancellation)
                    } else {
                        guard errno == ENOENT else { throw SFTPEditError.unstableFile }
                        fingerprint = nil
                    }
                    try SFTPEditCacheCleanup.remove(root: root, id: id, name: work.name, fingerprint: fingerprint, cancellation: cancellation)
                }.value
                runtime.removeValue(forKey: id); works.removeAll { $0.id == id }
            } catch {
                run.ending = nil; run.cleanupInProgress = false
                errorMessage = "清理未完成，尚存檔案保留在 SFTP Edits。\(error.localizedDescription)"
            }
        }
    }

    var needsQuitConfirmation: Bool {
        works.contains { $0.hasUnsavedChanges || [.watching, .waiting, .uploading, .failed, .conflict, .unknown].contains($0.state) }
    }

    func pauseForQuit() {
        for id in Array(runtime.keys) {
            runtime[id]?.monitor?.stop(); runtime[id]?.monitor = nil
            runtime[id]?.connection?.cancelEditTransfers(id)
            if work(id)?.cleanupStarted != true { update(id) { if $0.state != .stopped { $0.state = .paused } } }
        }
    }
}
