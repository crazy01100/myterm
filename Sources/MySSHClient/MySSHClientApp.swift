import SwiftUI

@main
struct MySSHClientApp: App {
    @StateObject private var hostStore = HostStore()
    @StateObject private var knownHostsStore = KnownHostsStore()
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var dataTransferCoordinator = DataTransferCoordinator()
    @StateObject private var shortcutStore = AppShortcutStore()
    @StateObject private var syncSettingsStore = SyncSettingsStore()
    @StateObject private var cloudAccountStore = CloudAccountStore()
    @StateObject private var vaultSetupStore = VaultSetupStore()
    @StateObject private var automaticMetadataSyncStore = AutomaticMetadataSyncStore()
    @StateObject private var unifiedSyncSetupStore = UnifiedSyncSetupStore()
    @StateObject private var appUpdaterStore = AppUpdaterStore()
    @AppStorage(AppTheme.storageKey) private var selectedTheme = AppTheme.automatic.rawValue

    private var preferredColorScheme: ColorScheme? {
        AppTheme(rawValue: selectedTheme)?.colorScheme
    }

    var body: some Scene {
        WindowGroup("MyTerm") {
            AppRootView(
                hostStore: hostStore,
                syncSettingsStore: syncSettingsStore,
                cloudAccountStore: cloudAccountStore,
                vaultSetupStore: vaultSetupStore,
                automaticMetadataSyncStore: automaticMetadataSyncStore
            )
                .environmentObject(hostStore)
                .environmentObject(knownHostsStore)
                .environmentObject(sessionManager)
                .environmentObject(shortcutStore)
                .environmentObject(syncSettingsStore)
                .environmentObject(cloudAccountStore)
                .environmentObject(vaultSetupStore)
                .environmentObject(automaticMetadataSyncStore)
                .environmentObject(unifiedSyncSetupStore)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("檢查更新…") {
                    appUpdaterStore.checkForUpdates()
                }
                .disabled(!appUpdaterStore.canCheckForUpdates)
            }
            DataTransferCommands(coordinator: dataTransferCoordinator)
        }

        Settings {
            SettingsView()
                .environmentObject(hostStore)
                .environmentObject(dataTransferCoordinator)
                .environmentObject(shortcutStore)
                .environmentObject(syncSettingsStore)
                .environmentObject(cloudAccountStore)
                .environmentObject(vaultSetupStore)
                .environmentObject(automaticMetadataSyncStore)
                .environmentObject(unifiedSyncSetupStore)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}

private struct AppRootView: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var syncSettingsStore: SyncSettingsStore
    @ObservedObject var cloudAccountStore: CloudAccountStore
    @ObservedObject var vaultSetupStore: VaultSetupStore
    @ObservedObject var automaticMetadataSyncStore: AutomaticMetadataSyncStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ContentView()
            .task {
                // Unlock the single local vault root once for this process so
                // account, sync and host-password access share one prompt.
                do {
                    try LocalSecretVaultStore.warmUp()
                } catch {
                    NSLog("MyTerm local secret vault warm-up failed: %@", error.localizedDescription)
                }
                await cloudAccountStore.restoreIfPossible()
                automaticMetadataSyncStore.updateAvailability(
                    settings: syncSettingsStore,
                    accountStore: cloudAccountStore
                )
                requestSync(.launch)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                requestSync(.foreground)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5 * 60))
                    guard !Task.isCancelled else { return }
                    requestSync(.periodic)
                }
            }
            .onChange(of: hostStore.hosts) { _, _ in
                guard !automaticMetadataSyncStore.isApplyingRemoteChanges else { return }
                automaticMetadataSyncStore.localInventoryDidChange(
                    hostStore: hostStore,
                    settings: syncSettingsStore,
                    accountStore: cloudAccountStore,
                    vaultSetupStore: vaultSetupStore
                )
            }
            .onChange(of: hostStore.groups) { _, _ in
                guard !automaticMetadataSyncStore.isApplyingRemoteChanges else { return }
                automaticMetadataSyncStore.localInventoryDidChange(
                    hostStore: hostStore,
                    settings: syncSettingsStore,
                    accountStore: cloudAccountStore,
                    vaultSetupStore: vaultSetupStore
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .myTermPasswordDidChange)) { _ in
                automaticMetadataSyncStore.localInventoryDidChange(
                    hostStore: hostStore,
                    settings: syncSettingsStore,
                    accountStore: cloudAccountStore,
                    vaultSetupStore: vaultSetupStore
                )
            }
            .onChange(of: syncSettingsStore.metadataSyncEnabled) { _, enabled in
                if enabled { requestSync(.manual) }
                else {
                    automaticMetadataSyncStore.updateAvailability(
                        settings: syncSettingsStore,
                        accountStore: cloudAccountStore
                    )
                }
            }
            .onChange(of: cloudAccountStore.state) { _, _ in
                automaticMetadataSyncStore.updateAvailability(
                    settings: syncSettingsStore,
                    accountStore: cloudAccountStore
                )
                requestSync(.foreground)
            }
            .onChange(of: vaultSetupStore.state) { _, _ in requestSync(.foreground) }
            .onChange(of: vaultSetupStore.cloudEnvelopeState) { _, _ in requestSync(.foreground) }
            .confirmationDialog(
                "雲端資料剛在其他裝置更新",
                isPresented: Binding(
                    get: { automaticMetadataSyncStore.pendingConfirmation != nil },
                    set: { presented in
                        if !presented, automaticMetadataSyncStore.pendingConfirmation != nil {
                            automaticMetadataSyncStore.declineRecentUpdate()
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("更新並同步") {
                    automaticMetadataSyncStore.confirmRecentUpdate(
                        hostStore: hostStore,
                        settings: syncSettingsStore,
                        accountStore: cloudAccountStore,
                        vaultSetupStore: vaultSetupStore
                    )
                }
                Button("不更新", role: .cancel) {
                    automaticMetadataSyncStore.declineRecentUpdate()
                }
            } message: {
                Text(recentUpdateMessage)
            }
    }

    private var recentUpdateMessage: String {
        let target = automaticMetadataSyncStore.pendingConfirmation?.title ?? "這筆資料"
        return "\(target)在最近五分鐘內已由另一台 Mac 更新。若選擇「更新並同步」，將以這台 Mac 目前的內容建立下一個版本並同步到雲端。"
    }

    private func requestSync(_ trigger: AutomaticMetadataSyncTrigger) {
        automaticMetadataSyncStore.request(
            trigger: trigger,
            hostStore: hostStore,
            settings: syncSettingsStore,
            accountStore: cloudAccountStore,
            vaultSetupStore: vaultSetupStore
        )
    }
}

private struct DataTransferCommands: Commands {
    @ObservedObject var coordinator: DataTransferCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandMenu("資料") {
            Button("匯入主機資料…") {
                coordinator.request(.importHosts)
                openSettings()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("匯出主機資料…") {
                coordinator.request(.exportHosts)
                openSettings()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
