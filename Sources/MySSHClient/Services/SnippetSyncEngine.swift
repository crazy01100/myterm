import Foundation

enum SnippetSyncPass { case completed, conflicts, pending }

@MainActor
enum SnippetSyncEngine {
    static func perform(store: CommandSnippetStore, project: String, uid: String, token: String,
                        key: VaultMasterKey, deviceID: UUID, backend: any SnippetSyncBackend,
                        validate: () throws -> Void) async throws -> SnippetSyncPass {
        let scope = SnippetSyncPolicy.scope(project: project, uid: uid), generation = store.generation
        try validate()
        let documents = try await backend.fetch(ownerUID: uid, idToken: token)
        try validate()
        let values = try documents.map { try CommandSnippetSyncCodec.decrypt($0.record, projectID: project, ownerUID: uid, masterKey: key) }
        try store.mergeRemote(values, scope: scope, generation: generation)
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.record.id, $0) })
        let pending = store.partition.entries.filter { !$0.needsReview && $0.value != $0.baseline }
        guard documents.count + pending.filter({ byID[$0.id] == nil }).count <= SnippetSyncPolicy.maximumEntries else { throw SnippetSyncError.capacity }
        for entry in pending {
            try validate()
            // Re-read latest local intent immediately before encryption, not a stale UI snapshot.
            guard let current = store.partition.entries.first(where: { $0.id == entry.id }), !current.needsReview,
                  current.value != current.baseline else { continue }
            let sent = SnippetRemoteValue(id: current.id, value: current.value, revision: current.revision + 1)
            let encrypted = try CommandSnippetSyncCodec.encrypt(sent, projectID: project, ownerUID: uid, masterKey: key, deviceID: deviceID)
            try await backend.write(encrypted, expectedUpdateTime: byID[current.id]?.updateTime, ownerUID: uid, idToken: token)
            try validate()
            try store.acknowledge(sent, scope: scope, generation: generation)
        }
        if store.reviewCount > 0 { return .conflicts }
        if store.partition.entries.contains(where: { $0.value != $0.baseline }) { return .pending }
        return .completed
    }
}
