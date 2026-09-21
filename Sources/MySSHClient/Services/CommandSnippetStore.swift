import Foundation
import Combine
import Darwin

@MainActor
final class CommandSnippetStore: ObservableObject {
    @Published private(set) var snippets: [CommandSnippet] = []
    @Published private(set) var loadError: String?
    @Published private(set) var activeScope = "local"
    @Published private(set) var changeRevision = 0
    @Published private(set) var syncMessage = "保存在這台 Mac"
    private var state = SnippetLibraryState()
    private let fileURL: URL
    private let persist: (Data, URL) throws -> Void
    private(set) var generation = UUID()
    private var accountScope: String?

    init(fileURL: URL = AppPaths.commandSnippetsFile,
         persist: @escaping (Data, URL) throws -> Void = CommandSnippetStore.writePrivateFile) {
        self.fileURL = fileURL
        self.persist = persist
        reload()
    }
    var hasSyncScope: Bool { state.partitions[activeScope]?.enrolled == true }
    var unboundCount: Int { state.partitions["local"]?.entries.compactMap(\.value).count ?? 0 }
    var reviewCount: Int { partition.entries.filter { $0.needsReview && $0.value != nil }.count }
    var partition: SnippetSyncPartition { state.partitions[activeScope] ?? .init() }
    func needsReview(_ id: UUID) -> Bool { partition.entries.first { $0.id == id }?.needsReview == true }
    func setSyncMessage(_ message: String) { syncMessage = message }

    func bindScope(_ scope: String?) {
        guard accountScope != scope else { return }
        accountScope = scope
        generation = UUID()
        // On sign-out retain the last local view, but no network worker is permitted to use it.
        if let scope { activeScope = state.partitions[scope] == nil ? "local" : scope }
        syncMessage = scope == nil ? "離線保存於這台 Mac" : (hasSyncScope ? "等待同步" : "保存在這台 Mac")
        publish()
    }
    func reload() {
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                state = SnippetLibraryState(); loadError = nil; publish(); return
            }
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 16 * 1024 * 1024 else { throw CommandSnippetError.unreadable }
            let data = try Data(contentsOf: fileURL)
            struct Header: Decodable { let schemaVersion: Int }
            let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
            var next: SnippetLibraryState
            if version == 1 {
                let old = try JSONDecoder().decode(CommandSnippetDocument.self, from: data)
                guard Set(old.snippets.map(\.id)).count == old.snippets.count else { throw CommandSnippetError.unreadable }
                let entries = try old.snippets.map { value in
                    SnippetSyncEntry(id: value.id, value: try value.validated(), baseline: nil)
                }
                next = SnippetLibraryState(); next.partitions["local"] = .init(entries: entries)
            } else if version == 2 { next = try JSONDecoder().decode(SnippetLibraryState.self, from: data) }
            else { throw CommandSnippetError.unsupportedVersion }
            try validate(next)
            state = next
            if accountScope == nil { activeScope = state.lastScope ?? "local" }
            generation = UUID(); loadError = nil; publish()
        } catch CommandSnippetError.unsupportedVersion { loadError = CommandSnippetError.unsupportedVersion.localizedDescription }
        catch { loadError = CommandSnippetError.unreadable.localizedDescription }
    }

    // Internal migration only. The existing SyncSettingsStore switch is the sole user control.
    @discardableResult
    func prepareUnifiedSync(scope: String, enabled: Bool) throws -> Bool {
        guard enabled else { return false }
        guard accountScope == scope else { throw SnippetSyncError.changed }
        if activeScope == scope && hasSyncScope && unboundCount == 0 { return true }
        try associateWithAccount(scope: scope)
        return true
    }

    private func associateWithAccount(scope: String) throws {
        guard accountScope == scope else { throw SnippetSyncError.changed }
        var next = state
        var target = next.partitions[scope] ?? .init()
        do {
            for entry in next.partitions["local"]?.entries ?? [] where entry.value != nil {
                guard !target.entries.contains(where: { $0.id == entry.id }) else { throw SnippetSyncError.conflict }
                target.entries.append(entry)
            }
            next.partitions["local"] = .init()
        }
        target.enrolled = true; next.partitions[scope] = target
        try commit(next, localChange: true, scope: scope)
        syncMessage = "等待同步"
    }
    func save(_ snippet: CommandSnippet) throws {
        let value = try snippet.validated()
        var next = state; var target = partition
        if let i = target.entries.firstIndex(where: { $0.id == value.id }) { target.entries[i].value = value }
        else {
            guard target.entries.compactMap(\.value).count < 500 else { throw CommandSnippetError.limit }
            target.entries.append(.init(id: value.id, value: value, baseline: nil))
        }
        next.partitions[activeScope] = target
        try commit(next, localChange: true)
    }
    func saveEdited(_ snippet: CommandSnippet, original: CommandSnippet?, scope: String) throws {
        guard scope == activeScope, snippets.first(where: { $0.id == snippet.id }) == original else { throw SnippetSyncError.changed }
        try save(snippet)
    }
    func delete(_ id: UUID) throws {
        var next = state; var target = partition
        if let i = target.entries.firstIndex(where: { $0.id == id }) {
            if target.entries[i].needsReview { target.entries.remove(at: i) }
            else { target.entries[i].value = nil }
        }
        next.partitions[activeScope] = target
        try commit(next, localChange: true)
    }
    func approveConflict(_ id: UUID) throws {
        var next = state; var target = partition
        guard let i = target.entries.firstIndex(where: { $0.id == id }), target.entries[i].value != nil else { throw SnippetSyncError.changed }
        target.entries[i].needsReview = false; next.partitions[activeScope] = target
        try commit(next, localChange: true)
    }
    func mergeRemote(_ remote: [SnippetRemoteValue], scope: String, generation expected: UUID) throws {
        try validateScope(scope, generation: expected)
        var next = state
        next.partitions[scope] = try SnippetSyncPolicy.merge(partition, remote: remote)
        try commit(next, localChange: false)
    }
    func acknowledge(_ sent: SnippetRemoteValue, scope: String, generation expected: UUID) throws {
        try validateScope(scope, generation: expected)
        var next = state; var target = partition
        guard let i = target.entries.firstIndex(where: { $0.id == sent.id }) else { throw SnippetSyncError.changed }
        // Preserve edits/deletion that occurred while this request was in flight.
        target.entries[i].baseline = sent.value; target.entries[i].revision = sent.revision
        next.partitions[scope] = target
        try commit(next, localChange: false)
    }
    func validateScope(_ scope: String, generation expected: UUID) throws {
        guard loadError == nil, accountScope == scope, activeScope == scope, generation == expected, hasSyncScope else { throw SnippetSyncError.changed }
    }
    private func publish() { snippets = partition.entries.compactMap(\.value) }
    private func validate(_ value: SnippetLibraryState) throws {
        guard value.schemaVersion == 2, value.partitions.count <= 32,
              value.lastScope == nil || value.partitions[value.lastScope!] != nil else { throw SnippetSyncError.invalidData }
        for (key, part) in value.partitions {
            guard key == "local" || (key.count == 64 && key.allSatisfy({ $0.isHexDigit })) else { throw SnippetSyncError.invalidData }
            try SnippetSyncPolicy.validate(part)
        }
    }
    private func commit(_ value: SnippetLibraryState, localChange: Bool, scope: String? = nil) throws {
        guard loadError == nil else { throw CommandSnippetError.unreadable }
        var next = value; next.lastScope = scope ?? activeScope
        try validate(next)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 16 * 1024 * 1024 else { throw CommandSnippetError.storageLimit }
        try persist(data, fileURL)
        state = next
        if let scope, scope != activeScope { activeScope = scope; generation = UUID() }
        publish()
        if localChange { changeRevision += 1 }
    }

    // Write the complete replacement with private permissions before atomic publication.
    nonisolated static func writePrivateFile(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".snippet-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? manager.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
