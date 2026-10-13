import Foundation
import Combine
import Darwin

@MainActor
final class SFTPBookmarkStore: ObservableObject {
    @Published private(set) var localBookmarks: [LocalDirectoryBookmark] = []
    @Published private(set) var bookmarks: [RemoteDirectoryBookmark] = []
    @Published private(set) var loadError: String?
    @Published private(set) var activeScope = "local"
    @Published private(set) var changeRevision = 0
    @Published private(set) var syncMessage = "保存在這台 Mac"
    private var state = BookmarkLibraryState()
    private let fileURL: URL
    private let persist: (Data, URL) throws -> Void
    private(set) var generation = UUID()
    private var accountScope: String?

    init(fileURL: URL = AppPaths.sftpBookmarksFile,
         persist: @escaping (Data, URL) throws -> Void = SFTPBookmarkStore.writePrivateFile) {
        self.fileURL = fileURL
        self.persist = persist
        reload()
    }
    var hasSyncScope: Bool { state.partitions[activeScope]?.enrolled == true }
    var unboundCount: Int { state.partitions["local"]?.entries.compactMap(\.value).count ?? 0 }
    var reviewCount: Int { partition.entries.filter { $0.needsReview && $0.value != nil }.count }
    var partition: BookmarkSyncPartition { state.partitions[activeScope] ?? .init() }
    func needsReview(_ id: UUID) -> Bool { partition.entries.first { $0.id == id }?.needsReview == true }
    func setSyncMessage(_ message: String) { syncMessage = message }

    func bindScope(_ scope: String?, preserveOffline: Bool = false) {
        let nextScope = scope ?? (preserveOffline ? (accountScope ?? state.lastScope ?? "local") : "local")
        guard accountScope != scope || activeScope != nextScope else { return }
        accountScope = scope
        activeScope = nextScope
        generation = UUID()
        syncMessage = scope == nil ? "離線保存於這台 Mac" : "等待同步"
        publish()
    }

    func reload() {
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                state = BookmarkLibraryState(); loadError = nil; publish(); return
            }
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 16 * 1024 * 1024 else { throw BookmarkError.unreadable }
            let data = try Data(contentsOf: fileURL)
            struct Header: Decodable { let schemaVersion: Int }
            let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
            guard version == 1 else { throw BookmarkError.unsupportedVersion }
            let next = try JSONDecoder().decode(BookmarkLibraryState.self, from: data)
            try validate(next)
            state = next
            generation = UUID(); loadError = nil; publish()
        } catch BookmarkError.unsupportedVersion { loadError = BookmarkError.unsupportedVersion.localizedDescription }
        catch { loadError = BookmarkError.unreadable.localizedDescription }
    }

    // Internal migration only. The existing SyncSettingsStore switch is the sole user control.
    @discardableResult
    func prepareUnifiedSync(scope: String, enabled: Bool) throws -> Bool {
        guard enabled else { return false }
        guard accountScope == scope else { throw BookmarkSyncError.changed }
        if activeScope == scope && hasSyncScope && unboundCount == 0 { return true }
        try associateWithAccount(scope: scope)
        return true
    }

    private func associateWithAccount(scope: String) throws {
        guard accountScope == scope else { throw BookmarkSyncError.changed }
        var next = state
        var target = next.partitions[scope] ?? .init()
        do {
            for entry in next.partitions["local"]?.entries ?? [] where entry.value != nil {
                guard !target.entries.contains(where: { $0.id == entry.id }) else { throw BookmarkSyncError.conflict }
                target.entries.append(entry)
            }
            next.partitions["local"] = .init()
        }
        target.enrolled = true; next.partitions[scope] = target
        try commit(next, localChange: true, scope: scope)
        syncMessage = "等待同步"
    }
    func save(_ bookmark: RemoteDirectoryBookmark) throws {
        let value = try bookmark.validated()
        var next = state; var target = partition
        guard !target.entries.contains(where: { $0.id != value.id && !$0.needsReview && $0.value?.sameLocation(as: value) == true }) else { throw BookmarkError.duplicate }
        if let i = target.entries.firstIndex(where: { $0.id == value.id }) { target.entries[i].value = value }
        else {
            guard target.entries.compactMap(\.value).count < 500 else { throw BookmarkError.limit }
            target.entries.append(.init(id: value.id, value: value, baseline: nil))
        }
        next.partitions[activeScope] = target
        try commit(next, localChange: true)
    }
    func saveEdited(_ bookmark: RemoteDirectoryBookmark, original: RemoteDirectoryBookmark?, scope: String) throws {
        guard scope == activeScope, bookmarks.first(where: { $0.id == bookmark.id }) == original else { throw BookmarkSyncError.changed }
        try save(bookmark)
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
        guard let i = target.entries.firstIndex(where: { $0.id == id }), target.entries[i].needsReview,
              var chosen = target.entries[i].value else { throw BookmarkError.changed }
        // Apply to a live canonical record where possible; deleted UUIDs are never resurrected.
        if let live = target.entries.firstIndex(where: { !$0.needsReview && $0.value?.sameLocation(as: chosen) == true }) {
            chosen.id = target.entries[live].id; target.entries[live].value = chosen
        } else {
            chosen.id = UUID(); target.entries.append(.init(id: chosen.id, value: chosen))
        }
        target.entries.removeAll { $0.needsReview && $0.value?.sameLocation(as: chosen) == true }
        next.partitions[activeScope] = target
        try commit(next, localChange: true)
    }

    func saveLocal(_ bookmark: LocalDirectoryBookmark, original: LocalDirectoryBookmark?) throws {
        let value = try bookmark.validated()
        guard state.local.first(where: { $0.id == value.id }) == original else { throw BookmarkError.changed }
        guard !state.local.contains(where: { $0.id != value.id && $0.path == value.path }) else { throw BookmarkError.duplicate }
        var next = state
        next.local.removeAll { $0.id == value.id }; next.local.append(value)
        try commit(next, localChange: false)
    }
    func deleteLocal(_ original: LocalDirectoryBookmark) throws {
        guard state.local.contains(original) else { throw BookmarkError.changed }
        var next = state; next.local.removeAll { $0.id == original.id }
        try commit(next, localChange: false)
    }
    func deleteRemote(_ original: RemoteDirectoryBookmark, scope: String) throws {
        guard scope == activeScope, bookmarks.contains(original) else { throw BookmarkError.changed }
        try delete(original.id)
    }
    func resolve(_ original: RemoteDirectoryBookmark, scope: String) throws {
        guard scope == activeScope, bookmarks.contains(original) else { throw BookmarkError.changed }
        try approveConflict(original.id)
    }

    func mergeRemote(_ remote: [BookmarkRemoteValue], scope: String, generation expected: UUID) throws {
        try validateScope(scope, generation: expected)
        var next = state
        next.partitions[scope] = try BookmarkSyncPolicy.merge(partition, remote: remote)
        try commit(next, localChange: false)
    }
    func acknowledge(_ sent: BookmarkRemoteValue, scope: String, generation expected: UUID) throws {
        try validateScope(scope, generation: expected)
        var next = state; var target = partition
        guard let i = target.entries.firstIndex(where: { $0.id == sent.id }) else { throw BookmarkSyncError.changed }
        // Preserve edits/deletion that occurred while this request was in flight.
        target.entries[i].baseline = sent.value; target.entries[i].revision = sent.revision
        next.partitions[scope] = target
        try commit(next, localChange: false)
    }
    func validateScope(_ scope: String, generation expected: UUID) throws {
        guard loadError == nil, accountScope == scope, activeScope == scope, generation == expected, hasSyncScope else { throw BookmarkSyncError.changed }
    }
    private func publish() {
        localBookmarks = state.local.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        bookmarks = partition.entries.compactMap(\.value).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func validate(_ value: BookmarkLibraryState) throws {
        guard value.schemaVersion == 1, value.partitions.count <= 32,
              value.lastScope == nil || value.partitions[value.lastScope!] != nil else { throw BookmarkSyncError.invalidData }
        guard value.local.count <= 500, Set(value.local.map(\.id)).count == value.local.count,
              Set(value.local.map(\.path)).count == value.local.count else { throw BookmarkError.limit }
        for item in value.local { guard try item.validated() == item else { throw BookmarkError.invalid } }
        for (key, part) in value.partitions {
            guard key == "local" || (key.count == 64 && key.allSatisfy({ $0.isHexDigit })) else { throw BookmarkSyncError.invalidData }
            try BookmarkSyncPolicy.validate(part)
        }
    }
    private func commit(_ value: BookmarkLibraryState, localChange: Bool, scope: String? = nil) throws {
        guard loadError == nil else { throw BookmarkError.unreadable }
        var next = value
        let savedScope = scope ?? activeScope
        if next.partitions[savedScope] != nil { next.lastScope = savedScope }
        try validate(next)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 16 * 1024 * 1024 else { throw BookmarkError.limit }
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
        let temporary = directory.appendingPathComponent(".bookmark-\(UUID().uuidString)")
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
