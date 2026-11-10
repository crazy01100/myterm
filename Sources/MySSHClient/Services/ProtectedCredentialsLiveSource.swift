import Combine
import Foundation

/// Connects existing metadata and host-password APIs. It never enumerates vault
/// entries and does not alter the encryption schema, sync settings or root ACL.
@MainActor
enum ProtectedCredentialsLiveSource {
    static let clipboard = SensitiveClipboardStore(pasteboard: SystemSensitivePasteboard(), observeSystem: true)
    private static let changes = CredentialChangeTracker(notification: .myTermPasswordDidChange)
    private static let readQueue = DispatchQueue(label: "MyTerm.credentials.read", qos: .userInitiated)
    private static var clipboardInventory: AnyCancellable?
    private static var clipboardPasswordObserver: NSObjectProtocol?

    static func makeStore() -> ProtectedCredentialsStore {
        // Install the mutation clock before any reader can start.
        _ = changes
        return ProtectedCredentialsStore(authentication: LocalUserAuthentication(), clipboard: clipboard) { id, complete in
            let request = ProtectedCredentialReadRequest.start(hostID: id, queue: readQueue,
                load: { try KeychainStore.passwordData(for: $0) }, complete: complete)
            return { request.cancel() }
        }
    }

    static func bind(_ store: ProtectedCredentialsStore, to hostStore: HostStore) -> [AnyCancellable] {
        // This app-lifetime observer survives the last credentials view/window.
        if clipboardInventory == nil {
            clipboardInventory = hostStore.$hosts.sink { hosts in clipboard.reconcile(hosts: hosts) }
            clipboardPasswordObserver = NotificationCenter.default.addObserver(
                forName: .myTermPasswordDidChange, object: nil, queue: .main) { note in
                guard let id = note.object as? UUID else { return }
                MainActor.assumeIsolated { clipboard.invalidate(hostID: id) }
            }
        }
        store.setSourceIdentity(currentHost: { [weak hostStore] in hostStore?.profile(id: $0) },
                                revision: { changes.generation(for: $0) })
        return [
            hostStore.$hosts.sink { [weak store] hosts in store?.updateHosts(hosts) },
            NotificationCenter.default.publisher(for: .myTermPasswordDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak store] note in
                    if let id = note.object as? UUID { store?.passwordDidChange(hostID: id) }
                }
        ]
    }
}
