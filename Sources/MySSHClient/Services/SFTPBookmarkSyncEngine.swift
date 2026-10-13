import Foundation

enum BookmarkSyncPass { case completed, conflicts, pending }

@MainActor
enum SFTPBookmarkSyncEngine {
    static func perform(store: SFTPBookmarkStore, project: String, uid: String, token: String,
                        key: VaultMasterKey, deviceID: UUID, backend: any BookmarkSyncBackend,
                        validate: () throws -> Void) async throws -> BookmarkSyncPass {
        let scope = BookmarkSyncPolicy.scope(project: project, uid: uid), generation = store.generation
        try validate()
        let documents = try await backend.fetch(ownerUID: uid, idToken: token)
        try validate()
        let values = try documents.map { try SFTPBookmarkSyncCodec.decrypt($0.record, projectID: project, ownerUID: uid, masterKey: key) }
        try store.mergeRemote(values, scope: scope, generation: generation)
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.record.id, $0) })
        let pending = store.partition.entries.filter { !$0.needsReview && $0.value != $0.baseline }
        guard documents.count + pending.filter({ byID[$0.id] == nil }).count <= BookmarkSyncPolicy.maximumEntries else { throw BookmarkSyncError.capacity }
        for entry in pending {
            try validate()
            // Re-read latest local intent immediately before encryption, not a stale UI snapshot.
            guard let current = store.partition.entries.first(where: { $0.id == entry.id }), !current.needsReview,
                  current.value != current.baseline else { continue }
            let sent = BookmarkRemoteValue(id: current.id, value: current.value, revision: current.revision + 1)
            let encrypted = try SFTPBookmarkSyncCodec.encrypt(sent, projectID: project, ownerUID: uid, masterKey: key, deviceID: deviceID)
            try await backend.write(encrypted, expectedUpdateTime: byID[current.id]?.updateTime, ownerUID: uid, idToken: token)
            try validate()
            try store.acknowledge(sent, scope: scope, generation: generation)
        }
        if store.reviewCount > 0 { return .conflicts }
        if store.partition.entries.contains(where: { $0.value != $0.baseline }) { return .pending }
        return .completed
    }
}
