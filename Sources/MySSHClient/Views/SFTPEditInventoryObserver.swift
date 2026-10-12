import SwiftUI

/// Keeps the existing connection usable for browsing, but disables edit writes
/// when inventory removes the saved host or changes its connection identity.
struct SFTPEditInventoryObserver: ViewModifier {
    @EnvironmentObject private var hosts: HostStore
    let store: SFTPRemoteBrowserStore

    func body(content: Content) -> some View {
        content.onChange(of: hosts.hosts) { _, updated in
            store.validateEditingInventory(updated)
        }
    }
}
