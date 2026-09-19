import SwiftUI

@main
struct MySSHClientApp: App {
    @StateObject private var hostStore = HostStore()
    @StateObject private var knownHostsStore = KnownHostsStore()
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var connectionAuditStore = ConnectionAuditStore()
    @StateObject private var automaticConnectionAuditSyncStore = AutomaticConnectionAuditSyncStore()
    @StateObject private var dataTransferCoordinator = DataTransferCoordinator()
    @StateObject private var shortcutStore = AppShortcutStore()
    @StateObject private var syncSettingsStore = SyncSettingsStore()
    @StateObject private var cloudAccountStore = CloudAccountStore()
    @StateObject private var vaultSetupStore = VaultSetupStore()
    @StateObject private var automaticMetadataSyncStore = AutomaticMetadataSyncStore()
    @StateObject private var automaticSyncCoordinator = AutomaticSyncCoordinator()
    @StateObject private var unifiedSyncSetupStore = UnifiedSyncSetupStore()
    @StateObject private var appUpdaterStore = AppUpdaterStore()
    @StateObject private var appearanceStore = AppAppearanceStore()

    init() {
        do {
            try AppPaths.removeStaleSSHConnectionLogs()
        } catch {
            NSLog("MyTerm stale SSH diagnostic cleanup failed: %@", error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup("MyTerm") {
            AppRootView(
                hostStore: hostStore,
                connectionAuditStore: connectionAuditStore,
                syncSettingsStore: syncSettingsStore,
                cloudAccountStore: cloudAccountStore,
                vaultSetupStore: vaultSetupStore,
                automaticMetadataSyncStore: automaticMetadataSyncStore,
                automaticConnectionAuditSyncStore: automaticConnectionAuditSyncStore,
                automaticSyncCoordinator: automaticSyncCoordinator
            )
                .environmentObject(hostStore)
                .environmentObject(knownHostsStore)
                .environmentObject(sessionManager)
                .environmentObject(connectionAuditStore)
                .environmentObject(automaticConnectionAuditSyncStore)
                .environmentObject(automaticSyncCoordinator)
                .environmentObject(shortcutStore)
                .environmentObject(syncSettingsStore)
                .environmentObject(cloudAccountStore)
                .environmentObject(vaultSetupStore)
                .environmentObject(automaticMetadataSyncStore)
                .environmentObject(unifiedSyncSetupStore)
                .environmentObject(appearanceStore)
                .preferredColorScheme(appearanceStore.effectiveColorScheme)
                .tint(AppVisualTheme.accent)
                .frame(minWidth: 1120, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("檢查更新…") {
                    appUpdaterStore.checkForUpdates()
                }
                .disabled(!appUpdaterStore.canCheckForUpdates)
            }
            DataTransferCommands(coordinator: dataTransferCoordinator)
            QuickActionCommands(shortcuts: shortcutStore)
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
                .environmentObject(connectionAuditStore)
                .environmentObject(automaticConnectionAuditSyncStore)
                .environmentObject(automaticSyncCoordinator)
                .environmentObject(unifiedSyncSetupStore)
                .environmentObject(appearanceStore)
                .preferredColorScheme(appearanceStore.effectiveColorScheme)
                .tint(AppVisualTheme.accent)
                .background(AppVisualTheme.contentBackground)
        }
    }
}

@MainActor
final class AppAppearanceStore: ObservableObject {
    @Published private(set) var selectedTheme: AppTheme
    @Published private(set) var effectiveColorScheme: ColorScheme

    private let defaults: UserDefaults
    private var applicationAppearanceObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTheme = defaults.string(forKey: AppTheme.storageKey)
            .flatMap(AppTheme.init(rawValue:)) ?? .automatic
        selectedTheme = storedTheme
        effectiveColorScheme = storedTheme.colorScheme ?? Self.systemColorScheme()

        applicationAppearanceObservation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshForSystemAppearanceChange()
            }
        }
    }

    func selectTheme(rawValue: String) {
        guard let theme = AppTheme(rawValue: rawValue) else { return }
        defaults.set(theme.rawValue, forKey: AppTheme.storageKey)
        selectedTheme = theme
        effectiveColorScheme = theme.colorScheme ?? Self.systemColorScheme()
    }

    private func refreshForSystemAppearanceChange() {
        guard selectedTheme == .automatic else { return }
        let updatedScheme = Self.systemColorScheme()
        guard updatedScheme != effectiveColorScheme else { return }
        effectiveColorScheme = updatedScheme
    }

    private static func systemColorScheme() -> ColorScheme {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark
            : .light
    }
}

private struct AppRootView: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var connectionAuditStore: ConnectionAuditStore
    @ObservedObject var syncSettingsStore: SyncSettingsStore
    @ObservedObject var cloudAccountStore: CloudAccountStore
    @ObservedObject var vaultSetupStore: VaultSetupStore
    @ObservedObject var automaticMetadataSyncStore: AutomaticMetadataSyncStore
    @ObservedObject var automaticConnectionAuditSyncStore: AutomaticConnectionAuditSyncStore
    @ObservedObject var automaticSyncCoordinator: AutomaticSyncCoordinator

    var body: some View {
        ContentView()
            .task {
                configureSync()
                automaticSyncCoordinator.setActive(NSApplication.shared.isActive)
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
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                configureSync()
                automaticSyncCoordinator.setActive(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                automaticSyncCoordinator.setActive(false)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                requestSync(.wake)
            }
            .onAppear {
                configureSync()
                requestSync(.foreground)
            }
            .onChange(of: hostStore.hosts) { _, _ in
                guard !automaticMetadataSyncStore.isApplyingRemoteChanges else { return }
                requestSync(.localChange)
            }
            .onChange(of: hostStore.groups) { _, _ in
                guard !automaticMetadataSyncStore.isApplyingRemoteChanges else { return }
                requestSync(.localChange)
            }
            .onReceive(NotificationCenter.default.publisher(for: .myTermPasswordDidChange)) { _ in
                requestSync(.localChange)
            }
            .onChange(of: connectionAuditStore.synchronizationRevision) { _, _ in
                requestSync(.localChange)
            }
            .onChange(of: syncSettingsStore.metadataSyncEnabled) { _, enabled in
                if enabled { requestSync(.availability) }
                else {
                    automaticMetadataSyncStore.updateAvailability(
                        settings: syncSettingsStore,
                        accountStore: cloudAccountStore
                    )
                    requestSync(.foreground)
                }
            }
            .onChange(of: cloudAccountStore.state) { _, _ in
                automaticMetadataSyncStore.updateAvailability(
                    settings: syncSettingsStore,
                    accountStore: cloudAccountStore
                )
                requestSync(.availability)
            }
            .onChange(of: vaultSetupStore.state) { _, _ in requestSync(.availability) }
            .onChange(of: vaultSetupStore.cloudEnvelopeState) { _, _ in requestSync(.availability) }
            .confirmationDialog(
                "雲端資料剛在其他裝置更新",
                isPresented: Binding(
                    get: { automaticMetadataSyncStore.pendingConfirmation != nil },
                    set: { presented in
                        if !presented, automaticMetadataSyncStore.pendingConfirmation != nil {
                            automaticMetadataSyncStore.declineRecentUpdate()
                            automaticSyncCoordinator.showDeclinedConfirmation()
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("更新並同步") {
                    automaticMetadataSyncStore.acceptPendingConfirmation()
                    requestSync(.confirmedRecentOverwrite)
                }
                Button("不更新", role: .cancel) {
                    automaticMetadataSyncStore.declineRecentUpdate()
                    automaticSyncCoordinator.showDeclinedConfirmation()
                }
            } message: {
                Text(recentUpdateMessage)
            }
    }

    private var recentUpdateMessage: String {
        let target = automaticMetadataSyncStore.pendingConfirmation?.title ?? "這筆資料"
        return "\(target)在最近五分鐘內已由另一台 Mac 更新。若選擇「更新並同步」，將以這台 Mac 目前的內容建立下一個版本並同步到雲端。"
    }

    private func requestSync(_ trigger: AutomaticSyncTrigger) {
        automaticSyncCoordinator.request(trigger)
    }

    private func configureSync() {
        automaticSyncCoordinator.configure(context: {
            let uid = cloudAccountStore.state.signedInAccount?.uid ?? "signed-out"
            return .init(scope: MetadataSyncBaselineStore.ownerDigest(uid), enabled: syncSettingsStore.metadataSyncEnabled)
        }, prepare: {
            vaultSetupStore.prepareForAutomaticSync(account: cloudAccountStore.state.signedInAccount)
            automaticMetadataSyncStore.updateAvailability(settings: syncSettingsStore, accountStore: cloudAccountStore)
            automaticConnectionAuditSyncStore.updateAvailability(settings: syncSettingsStore, accountStore: cloudAccountStore)
        }, canRecoverSession: {
            syncSettingsStore.sessionRecoveryEnabled && cloudAccountStore.canRetrySessionRestore
        }, recoverSession: {
            guard syncSettingsStore.sessionRecoveryEnabled else { return }
            await cloudAccountStore.restoreIfPossible(retryTransientFailure: true)
        }, metadata: { trigger in
            await automaticMetadataSyncStore.synchronize(trigger: trigger, hostStore: hostStore,
                settings: syncSettingsStore, accountStore: cloudAccountStore, vaultSetupStore: vaultSetupStore)
        }, logs: { trigger in
            await automaticConnectionAuditSyncStore.synchronize(trigger: trigger, auditStore: connectionAuditStore,
                settings: syncSettingsStore, accountStore: cloudAccountStore, vaultSetupStore: vaultSetupStore)
        })
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
