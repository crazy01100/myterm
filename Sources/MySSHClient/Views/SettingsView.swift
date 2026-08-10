import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppTheme: String, CaseIterable, Identifiable {
    static let storageKey = "appearanceTheme"

    case automatic
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "自動（跟隨系統）"
        case .light: "淺色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum SettingsTab: Hashable {
    case accountAndSync
    case appearance
    case shortcuts
    case dataTransfer
}

private struct TransferJSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw HostTransferError.malformedFile
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PendingHostImport: Identifiable {
    let id = UUID()
    let payload: HostImportPayload
}

struct SettingsView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var dataTransferCoordinator: DataTransferCoordinator
    @EnvironmentObject private var shortcutStore: AppShortcutStore
    @EnvironmentObject private var syncSettingsStore: SyncSettingsStore
    @EnvironmentObject private var cloudAccountStore: CloudAccountStore
    @EnvironmentObject private var vaultSetupStore: VaultSetupStore
    @EnvironmentObject private var automaticMetadataSyncStore: AutomaticMetadataSyncStore
    @EnvironmentObject private var unifiedSyncSetupStore: UnifiedSyncSetupStore
    @StateObject private var metadataSyncPreviewStore = MetadataSyncPreviewStore()
    @StateObject private var syncDiagnosticsStore = SyncDiagnosticsStore()
    @AppStorage(AppTheme.storageKey) private var selectedTheme = AppTheme.automatic.rawValue
    @State private var selectedTab: SettingsTab = .appearance
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportFile: TransferJSONFile?
    @State private var exportFilename = "MyTerm-Hosts"
    @State private var pendingImport: PendingHostImport?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var shortcutEditorAction: AppShortcutAction?
    @State private var showingVaultCreation = false
    @State private var showingRecoveryKey = false
    @State private var vaultUnlockMethod: VaultUnlockMethod?
    @State private var showingMetadataSyncPreview = false
    @State private var showingCloudInitializationConfirmation = false
    @State private var showingEmptyLocalRestoreConfirmation = false
    @State private var showingManualMetadataSyncConfirmation = false
    @State private var showingManualMetadataDownloadConfirmation = false
    @State private var showingRemoteBaselineRecoveryConfirmation = false
    @State private var isApplyingRemoteMerge = false
    @State private var syncActionNotice: String?
    @State private var showingUnifiedSyncSetup = false
    @State private var showingSyncDiagnostics = false

    var body: some View {
        TabView(selection: $selectedTab) {
            accountAndSyncView
                .tabItem { Label("帳號與同步", systemImage: "icloud") }
                .tag(SettingsTab.accountAndSync)

            appearanceView
                .tabItem { Label("外觀", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)

            shortcutsView
                .tabItem { Label("快捷鍵", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)

            dataTransferView
                .tabItem { Label("匯入與匯出", systemImage: "arrow.left.arrow.right") }
                .tag(SettingsTab.dataTransfer)

        }
        .padding(14)
        .frame(width: 720, height: 590)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleSelectedImportFile
        )
        .fileExporter(
            isPresented: $showingExporter,
            document: exportFile,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                statusMessage = "主機資料已匯出。檔案不含密碼、私鑰內容或私鑰路徑。"
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            exportFile = nil
        }
        .sheet(item: $pendingImport) { pending in
            ImportPreviewView(payload: pending.payload) { message in
                statusMessage = message
            }
            .environmentObject(hostStore)
        }
        .sheet(item: $shortcutEditorAction) { action in
            ShortcutRecorderView(action: action, shortcutStore: shortcutStore)
        }
        .sheet(isPresented: $showingVaultCreation) {
            VaultCreationView {
                vaultSetupStore.create(passphrase: $0)
            }
        }
        .sheet(isPresented: $showingRecoveryKey) {
            if case .awaitingRecoveryKey(let recoveryKey, _) = vaultSetupStore.state {
                RecoveryKeyView(
                    recoveryKey: recoveryKey,
                    onConfirm: {
                        vaultSetupStore.confirmRecoveryKeySaved()
                        showingRecoveryKey = false
                    },
                    onDefer: {
                        vaultSetupStore.discardDisplayedRecoveryKey()
                        showingRecoveryKey = false
                    }
                )
            }
        }
        .sheet(item: $vaultUnlockMethod) { method in
            VaultUnlockView(method: method) { value in
                switch method {
                case .passphrase:
                    vaultSetupStore.restoreWithPassphrase(value)
                case .recoveryKey:
                    vaultSetupStore.restoreWithRecoveryKey(value)
                }
            }
        }
        .sheet(isPresented: $showingUnifiedSyncSetup) {
            UnifiedSyncActivationView(setupStore: unifiedSyncSetupStore)
                .environmentObject(hostStore)
                .environmentObject(syncSettingsStore)
                .environmentObject(cloudAccountStore)
                .environmentObject(vaultSetupStore)
        }
        .sheet(isPresented: $showingSyncDiagnostics) {
            SyncDiagnosticsView(store: syncDiagnosticsStore)
                .environmentObject(hostStore)
                .environmentObject(syncSettingsStore)
                .environmentObject(cloudAccountStore)
                .environmentObject(automaticMetadataSyncStore)
        }
        .sheet(isPresented: $showingMetadataSyncPreview) {
            if case .ready(let preview) = metadataSyncPreviewStore.state {
                MetadataSyncPreviewDetailView(preview: preview)
            }
        }
        .confirmationDialog(
            "建立雲端加密初始資料？",
            isPresented: $showingCloudInitializationConfirmation,
            titleVisibility: .visible
        ) {
            Button("上傳 \(currentMetadataUploadCount) 筆加密資料") {
                performEmptyCloudInitialization()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("MyTerm 會先再次確認雲端仍為空，再逐筆上傳已加密的群組與主機。不包含密碼或本機私鑰路徑，也不會修改這台 Mac 的資料。")
        }
        .confirmationDialog(
            "從雲端還原到這台空白 Mac？",
            isPresented: $showingEmptyLocalRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("還原 \(currentMetadataDownloadCount) 筆主機與群組") {
                performEmptyLocalCloudRestore()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("MyTerm 會再次確認雲端密文與預覽完全相同，先備份目前的空白主機資料，再在本機解密還原。密碼不會下載，私鑰型主機需要在這台 Mac 重新選擇私鑰。")
        }
        .confirmationDialog(
            "安全上傳本機變更？",
            isPresented: $showingManualMetadataSyncConfirmation,
            titleVisibility: .visible
        ) {
            Button("處理 \(currentManualMetadataActionCount) 筆變更") {
                performManualMetadataSync()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("MyTerm 會再次讀取雲端並與本機同步基線比較。只有雲端仍未改變時，才會逐筆加密上傳並建立下一個版本；密碼、私鑰路徑、刪除與下載都不包含在這次操作中。")
        }
        .confirmationDialog(
            "安全下載雲端變更？",
            isPresented: $showingManualMetadataDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("下載並套用 \(currentManualMetadataDownloadCount) 筆變更") {
                performManualMetadataDownload()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("MyTerm 會重新讀取並驗證雲端快照，先備份目前主機資料，再於本機解密與合併。密碼不會下載，既有的本機私鑰路徑不會被覆蓋，刪除與兩端衝突也不會自動套用。")
        }
        .confirmationDialog(
            "以雲端資料建立這台 Mac 的同步基線？",
            isPresented: $showingRemoteBaselineRecoveryConfirmation,
            titleVisibility: .visible
        ) {
            Button("建立同步基線") { performRemoteBaselineRecovery() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("這是針對已從雲端還原、但缺少同步基線的修復。雲端目前版本會被視為上次同步狀態；不會覆蓋本機或雲端。這台 Mac 現有的差異會保留，建立後改列為可審查的本機變更。")
        }
        .alert("無法完成操作", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知錯誤")
        }
        .onAppear { handleRequestedAction() }
        .onChange(of: dataTransferCoordinator.requestedAction) { _, _ in
            handleRequestedAction()
        }
        .onChange(of: cloudAccountStore.state) { _, state in
            vaultSetupStore.refresh(account: state.signedInAccount)
            metadataSyncPreviewStore.reset()
            syncActionNotice = nil
        }
        .onChange(of: hostStore.hosts) { _, _ in
            if !isApplyingRemoteMerge { metadataSyncPreviewStore.reset() }
        }
        .onChange(of: hostStore.groups) { _, _ in
            if !isApplyingRemoteMerge { metadataSyncPreviewStore.reset() }
        }
        .onChange(of: vaultSetupStore.state) { _, state in
            if case .awaitingRecoveryKey = state {
                showingVaultCreation = false
                showingRecoveryKey = true
            }
        }
    }

    private var accountAndSyncView: some View {
        Form {
            Section("目前狀態") {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(syncSettingsStore.metadataSyncEnabled ? "跨裝置同步已啟用" : "純本機模式")
                        Text(syncSettingsStore.metadataSyncEnabled
                            ? "主機、群組與已儲存密碼會先在這台 Mac 加密，再同步至雲端。"
                            : "不需要帳號；主機資料與 Keychain 密碼都不會離開這台 Mac。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appBuildDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: syncSettingsStore.metadataSyncEnabled
                        ? "checkmark.icloud.fill"
                        : "externaldrive.fill.badge.checkmark")
                        .foregroundStyle(.green)
                }
            }

            Section("Google 帳號") {
                cloudAccountView
            }

            Section("跨裝置同步") {
                Toggle("同步主機、群組與密碼", isOn: Binding(
                    get: { syncSettingsStore.metadataSyncEnabled },
                    set: { enabled in
                        if enabled {
                            guard cloudAccountStore.state.signedInAccount != nil else {
                                errorMessage = "請先登入要用來同步的 Google 帳戶。"
                                return
                            }
                            unifiedSyncSetupStore.reset()
                            showingUnifiedSyncSetup = true
                            unifiedSyncSetupStore.prepare(accountStore: cloudAccountStore)
                        } else {
                            do {
                                try syncSettingsStore.setMetadataSyncEnabled(false)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                ))
                .disabled(
                    syncSettingsStore.availability != .ready
                        || cloudAccountStore.state.signedInAccount == nil
                )

                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(automaticMetadataSyncStore.status.message)
                        Text(lastMetadataSyncDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: automaticMetadataSyncStore.status.isError
                        ? "exclamationmark.icloud"
                        : "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(automaticMetadataSyncStore.status.isError ? .orange : .green)
                }

                Button("立即同步") {
                    automaticMetadataSyncStore.request(
                        trigger: .manual,
                        hostStore: hostStore,
                        settings: syncSettingsStore,
                        accountStore: cloudAccountStore,
                        vaultSetupStore: vaultSetupStore
                    )
                }
                .disabled(!syncSettingsStore.metadataSyncEnabled)

                Label("同步採端對端加密；雲端同步服務無法看到主機名稱、IP、帳號、備註或密碼。私鑰檔案與 known_hosts 不會同步。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("同步功能除錯") {
                Button {
                    showingSyncDiagnostics = true
                } label: {
                    Label("執行同步功能檢測…", systemImage: "stethoscope")
                }
                Text("MyTerm 會自動依序檢查登入、加密保管庫、雲端資料、同步基線、Keychain 密碼與自動同步狀態，並指出發生問題的階段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("登入不等於啟用同步。只有完成同步密語驗證、加密保管庫、首次合併與回讀驗證後，跨裝置同步開關才會正式打開。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await cloudAccountStore.restoreIfPossible()
            vaultSetupStore.refresh(account: cloudAccountStore.state.signedInAccount)
        }
    }

    private var appBuildDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開發版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        if let date = Bundle.main.object(forInfoDictionaryKey: "MyTermBuildDate") as? String {
            return "MyTerm \(version) · Build \(build) · \(date)"
        }
        return "MyTerm \(version) · Build \(build)"
    }

    private var lastMetadataSyncDescription: String {
        guard let date = automaticMetadataSyncStore.lastSuccessfulSyncAt else {
            return "這台 Mac 尚無自動同步成功紀錄。"
        }
        return "上次同步成功：\(date.formatted(date: .abbreviated, time: .standard))"
    }

    @ViewBuilder
    private var metadataSyncPreviewView: some View {
        if cloudAccountStore.state.signedInAccount == nil {
            Label("登入後才能建立同步預覽", systemImage: "arrow.triangle.2.circlepath.icloud")
                .foregroundStyle(.secondary)
        } else if !isVaultReadyForMetadataPreview {
            Label("請先完成本機加密保管庫與雲端封套", systemImage: "lock.icloud")
                .foregroundStyle(.secondary)
        } else {
            switch metadataSyncPreviewStore.state {
            case .idle:
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("尚未讀取主機同步資料")
                        Text("按下後只會讀取雲端密文，並在這台 Mac 解密比較。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                Button("建立只讀同步預覽…") { performMetadataSyncPreview() }

            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在安全讀取與比較加密主機資料…")
                }

            case .ready(let preview):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        previewCount("將上傳", preview.uploadCount, color: .blue)
                        previewCount("將下載", preview.downloadCount, color: .green)
                        previewCount("衝突", preview.conflictCount, color: preview.conflictCount == 0 ? .secondary : .orange)
                        previewCount("相同", preview.unchangedCount, color: .secondary)
                    }
                    Text("本機：\(preview.localGroupCount) 個群組、\(preview.localHostCount) 台主機；雲端：\(preview.remoteGroupCount) 個群組、\(preview.remoteHostCount) 台主機。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if preview.conflictCount > 0 {
                    Label("發現衝突；目前不提供執行同步，也不會覆蓋任何一端。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Label("預覽完成；尚未寫入或修改任何資料。", systemImage: "checkmark.shield.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                HStack {
                    Button("查看詳細預覽…") { showingMetadataSyncPreview = true }
                    Button("重新整理") { performMetadataSyncPreview(resetFirst: true) }
                }
                if case .ready = metadataSyncPreviewStore.baselineState {
                    metadataManualSyncControls()
                } else {
                    metadataInitializationControls(for: preview)
                }
                metadataBaselineControls(for: preview)

            case .failed(let message):
                Label("無法建立同步預覽", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("重試") { performMetadataSyncPreview(resetFirst: true) }
            }
        }
    }

    @ViewBuilder
    private func metadataInitializationControls(for preview: MetadataSyncPreview) -> some View {
        switch metadataSyncPreviewStore.initializationState {
        case .idle:
            if isEligibleForEmptyCloudInitialization(preview) {
                Button("將 \(preview.uploadCount) 筆加密資料保存到雲端…") {
                    showingCloudInitializationConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                Label("這只會建立雲端初始密文；持續同步開關仍不會啟用。", systemImage: "lock.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if preview.localGroupCount + preview.localHostCount == 0,
                      preview.remoteGroupCount + preview.remoteHostCount == 0,
                      preview.remoteTombstoneCount == 0 {
                Text("目前兩端都沒有主機或群組，無需建立雲端初始資料。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if preview.remoteGroupCount + preview.remoteHostCount + preview.remoteTombstoneCount > 0 {
                if isEligibleForEmptyLocalRestore(preview) {
                    Button("從雲端還原 \(preview.downloadCount) 筆到這台 Mac…") {
                        showingEmptyLocalRestoreConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    Label("只適用於沒有任何本機主機與群組的新 Mac；套用前會建立本機備份。", systemImage: "externaldrive.badge.icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("雲端已有同步紀錄；非空白裝置的合併與衝突選擇仍不會自動執行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .uploading(let completed, let total):
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("正在上傳加密初始資料（\(completed)／\(total)）…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .completed(let uploaded):
            Label("已上傳並重新下載驗證 \(uploaded) 筆加密資料；持續同步仍保持關閉。", systemImage: "checkmark.icloud.fill")
                .font(.callout)
                .foregroundStyle(.green)

        case .failed(let message):
            Label("雲端初始化未完成", systemImage: "exclamationmark.icloud")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("重新建立預覽") { performMetadataSyncPreview(resetFirst: true) }
        }
    }

    private func isEligibleForEmptyCloudInitialization(_ preview: MetadataSyncPreview) -> Bool {
        preview.uploadCount > 0
            && preview.downloadCount == 0
            && preview.conflictCount == 0
            && preview.unchangedCount == 0
            && preview.remoteTombstoneCount == 0
            && preview.remoteGroupCount == 0
            && preview.remoteHostCount == 0
            && preview.uploadCount == preview.localGroupCount + preview.localHostCount
    }

    @ViewBuilder
    private func metadataManualSyncControls() -> some View {
        if let plan = metadataSyncPreviewStore.manualPlan {
            if plan.canApplyRemoteChanges {
                switch metadataSyncPreviewStore.manualDownloadState {
                case .idle:
                    Divider()
                    Button("備份並套用 \(plan.downloadCount) 筆雲端變更…") {
                        showingManualMetadataDownloadConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    Text("只會套用雲端單方面的變更；先重新驗證，再備份本機資料。密碼不會下載。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .downloading:
                    Divider()
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在重新驗證、備份並安全合併雲端變更…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .completed(let downloaded):
                    Divider()
                    Label("已安全下載並套用 \(downloaded) 筆雲端變更。", systemImage: "checkmark.icloud.fill")
                        .font(.callout)
                        .foregroundStyle(.green)

                case .failed(let message):
                    Divider()
                    Label("雲端變更未套用", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("重新整理同步預覽") { performMetadataSyncPreview(resetFirst: true) }
                }
            } else {
                switch metadataSyncPreviewStore.manualSyncState {
            case .idle:
                if plan.canApplyLocalChanges {
                    Divider()
                    Button("安全處理 \(plan.uploadCount + plan.repairCount) 筆本機變更…") {
                        showingManualMetadataSyncConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    if plan.repairCount > 0 {
                        Text("另有 \(plan.repairCount) 筆只需修復本機同步基線，不會重複上傳。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if plan.downloadCount > 0 || plan.conflictCount > 0 {
                    Divider()
                    Label("這份預覽包含雲端變更、刪除或衝突；手動上傳已停用。", systemImage: "hand.raised.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

            case .syncing(let completed, let total):
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    Text("正在加密、上傳並更新本機基線（\(completed)／\(total)）…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .completed(let uploaded, let repaired):
                Divider()
                Label(
                    repaired > 0
                        ? "已驗證上傳 \(uploaded) 筆，並修復 \(repaired) 筆同步基線。"
                        : "已上傳並重新下載驗證 \(uploaded) 筆本機變更。",
                    systemImage: "checkmark.icloud.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)

            case .failed(let message):
                Divider()
                Label("手動同步已安全停止", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("重新整理同步預覽") { performMetadataSyncPreview(resetFirst: true) }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataBaselineControls(for preview: MetadataSyncPreview) -> some View {
        switch metadataSyncPreviewStore.baselineState {
        case .idle:
            if isEligibleForBaseline(preview) {
                Divider()
                Button("建立這 \(preview.unchangedCount) 筆資料的同步基線") {
                    performMetadataBaselineCreation()
                }
                .buttonStyle(.borderedProminent)
                Label("只會在這台 Mac 保存內容指紋、雲端 revision 與隨機裝置 ID；不保存主機內容或密碼。", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if metadataSyncPreviewStore.canEstablishRemoteAnchorBaseline {
                Divider()
                Button("以雲端資料建立這台 Mac 的同步基線…") {
                    showingRemoteBaselineRecoveryConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                Label("不會覆蓋任何一端；本機現有差異會保留為待上傳變更。", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let summary):
            Divider()
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("同步基線已就緒：\(summary.recordCount) 筆")
                    Text(revisionDescription(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Divider()
            Label("同步基線尚未建立", systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if isEligibleForBaseline(preview) {
                Button("重試建立基線") { performMetadataBaselineCreation() }
            }
        }
    }

    private func isEligibleForBaseline(_ preview: MetadataSyncPreview) -> Bool {
        let localCount = preview.localGroupCount + preview.localHostCount
        return localCount > 0
            && preview.unchangedCount == localCount
            && preview.uploadCount == 0
            && preview.downloadCount == 0
            && preview.conflictCount == 0
            && preview.remoteTombstoneCount == 0
    }

    private func revisionDescription(_ summary: MetadataSyncBaselineSummary) -> String {
        if summary.minimumRevision == summary.maximumRevision {
            return "目前全部為 revision \(summary.minimumRevision)。"
        }
        return "目前 revision \(summary.minimumRevision)～\(summary.maximumRevision)。"
    }

    private func isEligibleForEmptyLocalRestore(_ preview: MetadataSyncPreview) -> Bool {
        preview.localGroupCount == 0
            && preview.localHostCount == 0
            && preview.uploadCount == 0
            && preview.conflictCount == 0
            && preview.unchangedCount == 0
            && preview.downloadCount > 0
            && preview.downloadCount == preview.remoteGroupCount + preview.remoteHostCount
    }

    private var currentMetadataUploadCount: Int {
        guard case .ready(let preview) = metadataSyncPreviewStore.state else { return 0 }
        return preview.uploadCount
    }

    private var currentMetadataDownloadCount: Int {
        guard case .ready(let preview) = metadataSyncPreviewStore.state else { return 0 }
        return preview.downloadCount
    }

    private var currentManualMetadataActionCount: Int {
        guard let plan = metadataSyncPreviewStore.manualPlan else { return 0 }
        return plan.uploadCount + plan.repairCount
    }

    private var currentManualMetadataDownloadCount: Int {
        metadataSyncPreviewStore.manualPlan?.downloadCount ?? 0
    }

    private var isVaultReadyForMetadataPreview: Bool {
        guard case .ready = vaultSetupStore.state,
              vaultSetupStore.cloudEnvelopeState == .available else { return false }
        return true
    }

    private func previewCount(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(count))
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 58, alignment: .leading)
    }

    @ViewBuilder
    private var vaultSetupView: some View {
        switch vaultSetupStore.state {
        case .signedOut:
            Label("登入後才能建立同步用的加密保管庫", systemImage: "lock")
                .foregroundStyle(.secondary)

        case .notCreated:
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("尚未建立加密保管庫")
                    Text("建立動作目前只會在這台 Mac 保存主金鑰與加密封套，不會上傳資料。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield")
            }
            Button("建立加密保管庫…") { showingVaultCreation = true }

        case .working(let message):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message)
            }

        case .awaitingRecoveryKey:
            Label("復原金鑰尚未確認保存", systemImage: "key.horizontal")
                .foregroundStyle(.orange)
            Button("顯示這次產生的復原金鑰") { showingRecoveryKey = true }

        case .recoveryConfirmationRequired:
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("復原金鑰尚未完成保存")
                    Text("為避免重複顯示舊金鑰，MyTerm 會使舊封套失效並產生一把新的復原金鑰。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            Button("產生新的復原金鑰…") { vaultSetupStore.replaceUnconfirmedRecoveryKey() }

        case .ready(let summary):
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("這台 Mac 的加密保管庫已就緒")
                    Text(syncSettingsStore.metadataSyncEnabled
                        ? "主金鑰版本 \(summary.keyVersion)；復原金鑰已確認保存，同步已啟用。"
                        : "主金鑰版本 \(summary.keyVersion)；復原金鑰已確認保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
            }

        case .missingLocalMasterKey:
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("這台 Mac 缺少保管庫主金鑰")
                    Text("目前不會覆蓋任何本機資料；第二台 Mac 的密語／復原流程完成後才能取回。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("使用同步密語還原…") { vaultUnlockMethod = .passphrase }
                Button("使用復原金鑰還原…") { vaultUnlockMethod = .recoveryKey }
            }

        case .failed(let message):
            Label("無法讀取加密保管庫", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("重試") { vaultSetupStore.retry() }
        }
    }

    @ViewBuilder
    private var cloudEnvelopeView: some View {
        if cloudAccountStore.state.signedInAccount == nil {
            Label("登入後才能檢查雲端封套", systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
        } else {
            switch vaultSetupStore.cloudEnvelopeState {
            case .notChecked:
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("尚未檢查雲端同步服務")
                        Text("只有你按下按鈕後才會讀取目前帳號的加密封套。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud.and.arrow.down")
                }
                Button("檢查雲端保管庫") { performCloudEnvelopeCheck() }

            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在檢查雲端加密封套…")
                }

            case .notFound:
                Label("這個帳號尚未保存雲端加密封套", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
                if case .ready = vaultSetupStore.state {
                    Button("將加密封套保存到雲端…") { performCloudEnvelopeUpload() }
                    Text("只上傳已加密的 Master Key 封套與公開 KDF 參數；不包含主機、密碼、同步密語或復原金鑰。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("請先在這台 Mac 建立並確認加密保管庫。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .available:
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("雲端加密封套已就緒")
                        Text(syncSettingsStore.metadataSyncEnabled
                            ? "Master Key 密文封套已完成驗證，跨裝置同步已啟用。"
                            : "目前只有復原 Master Key 所需的密文封套；尚未啟用同步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud.fill")
                        .foregroundStyle(.green)
                }

            case .uploading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在保存加密封套…")
                }

            case .conflict:
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本機與雲端封套不同")
                        Text("MyTerm 已停止操作，沒有覆蓋任何一方。需要完成金鑰版本與衝突處理後才能繼續。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                }

            case .failed(let message):
                Label("無法存取雲端加密封套", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("重試") {
                    vaultSetupStore.retryCloudCheck()
                    performCloudEnvelopeCheck()
                }
            }
        }
    }

    @ViewBuilder
    private var cloudAccountView: some View {
        switch cloudAccountStore.state {
        case .unavailable(let message):
            Label("Google 登入尚未設定", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("純本機功能不受影響；設定完成前不會連線到雲端同步服務。")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .signedOut:
            Label("尚未登入", systemImage: "person.crop.circle")
            Button("使用 Google 帳號登入") {
                cloudAccountStore.signIn()
            }
            Text("登入只建立同步身分，不會自動上傳主機或密碼。")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .restoring:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在恢復 Google 登入狀態…")
            }

        case .signingIn:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("請在系統瀏覽器完成 Google 登入…")
                Spacer()
                Button("取消") { cloudAccountStore.cancelSignIn() }
            }

        case .signedIn(let account):
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.title)
                    if let email = account.email, email != account.title {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.green)
            }
            Text(syncSettingsStore.metadataSyncEnabled
                ? "登入完成；主機、群組與密碼同步已啟用。"
                : "登入完成；尚未啟用跨裝置同步。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("登出這台 Mac") { cloudAccountStore.signOut() }

        case .failed(let message):
            Label("Google 登入未完成", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("重新登入") {
                    cloudAccountStore.retryAfterFailure()
                    cloudAccountStore.signIn()
                }
                Button("清除本機登入狀態") { cloudAccountStore.signOut() }
            }
        }
    }

    private var appearanceView: some View {
        Form {
            Section("外觀") {
                Picker("Theme", selection: $selectedTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text("主題會套用到主機庫、設定與所有本機／SSH 終端機分頁。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsView: some View {
        Form {
            Section {
                Label("快捷鍵只會在 MyTerm 主視窗內生效，不會建立系統全域熱鍵。", systemImage: "macwindow")
                Label("填入密碼會直接從 macOS Keychain 送至目前分頁，不會使用剪貼簿。", systemImage: "lock.shield")
            }

            ForEach(AppShortcutCategory.allCases) { category in
                Section(category.title) {
                    ForEach(AppShortcutAction.allCases.filter { $0.category == category }) { action in
                        shortcutRow(action)
                    }
                }
            }

            Section {
                Button("恢復全部預設快捷鍵") {
                    shortcutStore.resetAll()
                }
            } footer: {
                Text("點擊快捷鍵即可錄製新的組合；按 Delete 可停用。重複與必要的 macOS 快捷鍵會被阻止。")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ action: AppShortcutAction) -> some View {
        HStack(spacing: 12) {
            Text(action.title)
            Spacer()
            Button {
                shortcutEditorAction = action
            } label: {
                Text(shortcutStore.shortcut(for: action)?.displayText ?? "停用")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 72)
            }
            .buttonStyle(.bordered)

            Menu {
                Button("重新設定…") { shortcutEditorAction = action }
                Button("停用") { try? shortcutStore.assign(nil, to: action) }
                Divider()
                Button("恢復預設") { shortcutStore.reset(action) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var dataTransferView: some View {
        Form {
            Section("支援格式") {
                formatRow(
                    title: "MyTerm JSON",
                    detail: "可匯入、可匯出；保留多層群組、主機、平台與連線演算法設定。",
                    symbol: "checkmark.circle.fill",
                    color: .green
                )
                formatRow(
                    title: "Termius 主機資料 JSON",
                    detail: "可匯入 MyTerm 匯出工具產生的 myterm-termius-host-export-v1 檔案。",
                    symbol: "checkmark.circle.fill",
                    color: .green
                )
                formatRow(
                    title: "CSV／Termius Vault 原始檔",
                    detail: "不支援直接匯入。CSV 僅供人工檢視，避免欄位與階層資訊遺失。",
                    symbol: "xmark.circle.fill",
                    color: .secondary
                )
            }

            Section("安全範圍") {
                Label("不匯入或匯出密碼、Passphrase、Token 與私鑰內容", systemImage: "lock.shield")
                Label("不匯出本機私鑰路徑；私鑰型主機會改用 SSH Agent／SSH Config", systemImage: "key.slash")
                Text("JSON 是未加密的主機中繼資料，仍可能包含 IP、使用者名稱與備註；請像一般設定備份一樣妥善保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("資料搬遷") {
                HStack(spacing: 12) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("選擇匯入檔…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        beginExport()
                    } label: {
                        Label("匯出 MyTerm JSON…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                Text("匯入前會先顯示預覽與重複資料數量；確認匯入時，MyTerm 會先在本機建立目前資料的備份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func formatRow(title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handleRequestedAction() {
        guard let action = dataTransferCoordinator.requestedAction else { return }
        selectedTab = .dataTransfer
        switch action {
        case .importHosts:
            showingImporter = true
        case .exportHosts:
            beginExport()
        }
        dataTransferCoordinator.consume(action)
    }

    private func handleSelectedImportFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > HostTransferService.maximumFileSize {
                throw HostTransferError.fileTooLarge
            }
            let payload = try HostTransferService.decodeImport(data: Data(contentsOf: url))
            pendingImport = PendingHostImport(payload: payload)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginExport() {
        do {
            exportFile = TransferJSONFile(data: try hostStore.exportTransferData())
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            exportFilename = "MyTerm-Hosts-\(formatter.string(from: .now))"
            showingExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performCloudEnvelopeCheck() {
        Task {
            do {
                guard let projectID = cloudAccountStore.firebaseProjectID else {
                    throw CloudConfigurationError.invalidProjectID
                }
                let token = try await cloudAccountStore.validIDToken()
                await vaultSetupStore.checkCloudEnvelope(projectID: projectID, idToken: token)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performCloudEnvelopeUpload() {
        Task {
            do {
                guard let projectID = cloudAccountStore.firebaseProjectID else {
                    throw CloudConfigurationError.invalidProjectID
                }
                let token = try await cloudAccountStore.validIDToken()
                await vaultSetupStore.uploadCloudEnvelope(projectID: projectID, idToken: token)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performMetadataSyncPreview(resetFirst: Bool = false) {
        if resetFirst { metadataSyncPreviewStore.reset() }
        Task {
            do {
                guard case .signedIn(let account) = cloudAccountStore.state else {
                    throw CloudAccountStoreError.notSignedIn
                }
                guard isVaultReadyForMetadataPreview else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                guard let projectID = cloudAccountStore.firebaseProjectID else {
                    throw CloudConfigurationError.invalidProjectID
                }
                let token = try await cloudAccountStore.validIDToken()
                metadataSyncPreviewStore.prepare(
                    projectID: projectID,
                    ownerUID: account.uid,
                    idToken: token,
                    localGroups: hostStore.groups,
                    localHosts: hostStore.hosts
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performEmptyCloudInitialization() {
        Task {
            do {
                guard case .signedIn(let account) = cloudAccountStore.state else {
                    throw CloudAccountStoreError.notSignedIn
                }
                guard isVaultReadyForMetadataPreview else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                guard let projectID = cloudAccountStore.firebaseProjectID else {
                    throw CloudConfigurationError.invalidProjectID
                }
                let token = try await cloudAccountStore.validIDToken()
                metadataSyncPreviewStore.initializeEmptyCloud(
                    projectID: projectID,
                    ownerUID: account.uid,
                    idToken: token,
                    currentGroups: hostStore.groups,
                    currentHosts: hostStore.hosts
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performMetadataBaselineCreation() {
        do {
            guard case .signedIn(let account) = cloudAccountStore.state else {
                throw CloudAccountStoreError.notSignedIn
            }
            let summary = try metadataSyncPreviewStore.establishBaseline(
                ownerUID: account.uid,
                currentGroups: hostStore.groups,
                currentHosts: hostStore.hosts
            )
            syncActionNotice = "已建立 \(summary.recordCount) 筆安全同步基線；尚未啟用自動同步。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performRemoteBaselineRecovery() {
        do {
            guard case .signedIn(let account) = cloudAccountStore.state else {
                throw CloudAccountStoreError.notSignedIn
            }
            let summary = try metadataSyncPreviewStore.establishRemoteAnchorBaseline(
                ownerUID: account.uid,
                currentGroups: hostStore.groups,
                currentHosts: hostStore.hosts
            )
            syncActionNotice = "已用雲端資料安全修復 \(summary.recordCount) 筆同步基線；本機資料未被覆蓋，請重新檢視待上傳變更。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performManualMetadataSync() {
        Task {
            do {
                guard case .signedIn(let account) = cloudAccountStore.state else {
                    throw CloudAccountStoreError.notSignedIn
                }
                guard isVaultReadyForMetadataPreview else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                guard let projectID = cloudAccountStore.firebaseProjectID else {
                    throw CloudConfigurationError.invalidProjectID
                }
                let token = try await cloudAccountStore.validIDToken()
                metadataSyncPreviewStore.syncLocalChanges(
                    projectID: projectID,
                    ownerUID: account.uid,
                    idToken: token,
                    currentGroups: hostStore.groups,
                    currentHosts: hostStore.hosts
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performManualMetadataDownload() {
        Task {
            do {
                guard case .signedIn(let account) = cloudAccountStore.state else {
                    throw CloudAccountStoreError.notSignedIn
                }
                guard isVaultReadyForMetadataPreview else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                guard let projectID = cloudAccountStore.firebaseProjectID else {
                    throw CloudConfigurationError.invalidProjectID
                }
                let token = try await cloudAccountStore.validIDToken()
                let result = try await metadataSyncPreviewStore.verifiedRemoteMerge(
                    projectID: projectID,
                    ownerUID: account.uid,
                    idToken: token,
                    currentGroups: hostStore.groups,
                    currentHosts: hostStore.hosts
                )
                isApplyingRemoteMerge = true
                defer { isApplyingRemoteMerge = false }
                let backupURL = try hostStore.applyVerifiedCloudMerge(result.document)
                try metadataSyncPreviewStore.commitRemoteMerge(
                    result,
                    ownerUID: account.uid,
                    currentGroups: hostStore.groups,
                    currentHosts: hostStore.hosts
                )
                syncActionNotice = "已安全下載並套用 \(result.downloadedCount) 筆雲端變更；套用前備份：\(backupURL.lastPathComponent)。密碼未下載。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performEmptyLocalCloudRestore() {
        Task {
            do {
                guard case .signedIn(let account) = cloudAccountStore.state else {
                    throw CloudAccountStoreError.notSignedIn
                }
                guard isVaultReadyForMetadataPreview else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                guard let projectID = cloudAccountStore.firebaseProjectID else {
                    throw CloudConfigurationError.invalidProjectID
                }
                let token = try await cloudAccountStore.validIDToken()
                let result = try await metadataSyncPreviewStore.verifiedEmptyLocalRestore(
                    projectID: projectID,
                    ownerUID: account.uid,
                    idToken: token,
                    currentGroups: hostStore.groups,
                    currentHosts: hostStore.hosts
                )
                let groupCount = result.document.groups.count
                let hostCount = result.document.hosts.count
                isApplyingRemoteMerge = true
                defer { isApplyingRemoteMerge = false }
                _ = try hostStore.restoreEmptyInventoryFromCloud(result.document)
                try metadataSyncPreviewStore.commitRemoteMerge(
                    result,
                    ownerUID: account.uid,
                    currentGroups: hostStore.groups,
                    currentHosts: hostStore.hosts
                )
                syncActionNotice = "已安全還原 \(groupCount) 個群組與 \(hostCount) 台主機並建立同步基線；密碼與私鑰路徑未下載。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MetadataSyncPreviewDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: MetadataSyncPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("同步預覽")
                    .font(.title2.weight(.semibold))
                Text("這是只讀結果；關閉視窗不會上傳、下載、刪除或修改資料。")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                summaryCard("將上傳", preview.uploadCount, "arrow.up.circle.fill", .blue)
                summaryCard("將下載", preview.downloadCount, "arrow.down.circle.fill", .green)
                summaryCard("衝突", preview.conflictCount, "exclamationmark.triangle.fill", .orange)
                summaryCard("相同", preview.unchangedCount, "equal.circle.fill", .secondary)
            }

            List(preview.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(for: item))
                        .foregroundStyle(color(for: item.disposition))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.displayName)
                                .fontWeight(.medium)
                            Text(item.recordType == .group ? "群組" : "主機")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Text("\(item.disposition.title) · \(item.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let revision = item.remoteRevision {
                            Text("雲端 revision \(revision)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)

            HStack {
                Label("密碼與本機私鑰路徑不在這份預覽中。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("關閉") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
    }

    private func summaryCard(_ title: String, _ count: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(count)).font(.headline)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func color(for disposition: MetadataSyncPreviewDisposition) -> Color {
        switch disposition {
        case .upload: .blue
        case .download: .green
        case .conflict: .orange
        case .unchanged, .remoteTombstone: .secondary
        }
    }

    private func symbol(for item: MetadataSyncPreviewItem) -> String {
        switch item.disposition {
        case .upload: "arrow.up.circle.fill"
        case .download: "arrow.down.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .unchanged: "equal.circle.fill"
        case .remoteTombstone: "trash.slash"
        }
    }
}

private extension CloudAccountState {
    var signedInAccount: FirebaseAccount? {
        guard case .signedIn(let account) = self else { return nil }
        return account
    }
}

private struct SyncDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var settings: SyncSettingsStore
    @EnvironmentObject private var accountStore: CloudAccountStore
    @EnvironmentObject private var automaticSyncStore: AutomaticMetadataSyncStore
    @ObservedObject var store: SyncDiagnosticsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("同步功能除錯")
                        .font(.title2.weight(.semibold))
                    Text("自動找出跨裝置同步在哪個階段出現問題。")
                        .foregroundStyle(.secondary)
                }
            }

            if store.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.currentStage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if store.didFinish {
                Label(diagnosticSummary, systemImage: diagnosticSummarySymbol)
                    .font(.headline)
                    .foregroundStyle(diagnosticSummaryColor)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.results.isEmpty {
                        ContentUnavailableView(
                            "準備檢測",
                            systemImage: "stethoscope",
                            description: Text("MyTerm 將依照實際同步流程自動完成檢查。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 270)
                    } else {
                        ForEach(store.results) { result in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: symbol(for: result.level))
                                    .font(.title3)
                                    .foregroundStyle(color(for: result.level))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.title)
                                        .font(.headline)
                                    Text(result.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            if result.id != store.results.last?.id {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

            HStack {
                Label("檢測只會讀取並驗證同步狀態，不會上傳、套用、刪除或覆蓋主機與密碼。讀取 Keychain 時，macOS 可能要求確認。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if !store.isRunning {
                    Button("重新檢測") { runDiagnostics() }
                }
                Button("關閉") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 700, height: 570)
        .interactiveDismissDisabled(store.isRunning)
        .task { runDiagnostics() }
        .onDisappear { store.cancel() }
    }

    private var diagnosticSummary: String {
        if store.hasFailure { return "檢測完成：發現需要處理的問題" }
        if store.hasWarning { return "檢測完成：同步可用，但有項目需要注意" }
        return "檢測完成：所有同步階段均正常"
    }

    private var diagnosticSummarySymbol: String {
        if store.hasFailure { return "xmark.octagon.fill" }
        if store.hasWarning { return "exclamationmark.triangle.fill" }
        return "checkmark.shield.fill"
    }

    private var diagnosticSummaryColor: Color {
        if store.hasFailure { return .red }
        if store.hasWarning { return .orange }
        return .green
    }

    private func runDiagnostics() {
        store.run(
            hostStore: hostStore,
            settings: settings,
            accountStore: accountStore,
            automaticSyncStore: automaticSyncStore
        )
    }

    private func symbol(for level: SyncDiagnosticLevel) -> String {
        switch level {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(for level: SyncDiagnosticLevel) -> Color {
        switch level {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private struct UnifiedSyncActivationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var settings: SyncSettingsStore
    @EnvironmentObject private var accountStore: CloudAccountStore
    @EnvironmentObject private var vaultSetupStore: VaultSetupStore
    @ObservedObject var setupStore: UnifiedSyncSetupStore
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var recoveryKeySaved = false

    private var setupMode: UnifiedSyncSetupMode? {
        guard case .awaitingPassphrase(let mode) = setupStore.state else { return nil }
        return mode
    }

    private var passphraseIsValid: Bool {
        guard passphrase.count >= 12, let setupMode else { return false }
        return !setupMode.requiresConfirmation || passphrase == confirmation
    }

    private var preventsInteractiveDismiss: Bool {
        switch setupStore.state {
        case .checking, .working:
            true
        case .completed(let recoveryKey):
            recoveryKey != nil && !recoveryKeySaved
        default:
            false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            content
            Spacer(minLength: 8)
            footer
        }
        .padding(26)
        .frame(width: 620, height: 500)
        .interactiveDismissDisabled(preventsInteractiveDismiss)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("啟用跨裝置同步")
                    .font(.title2.weight(.semibold))
                Text("主機、群組與密碼會一起同步；私鑰檔案與 known_hosts 保留在本機。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch setupStore.state {
        case .idle, .checking:
            progress("正在檢查這個 Google 帳戶的同步設定…")

        case .awaitingPassphrase(let mode):
            VStack(alignment: .leading, spacing: 14) {
                Text(mode.title)
                    .font(.headline)
                Text(mode == .create
                    ? "這組密語會保護新建立的端對端加密主金鑰。"
                    : "使用原本的同步密語，安全取回這個帳戶的端對端加密主金鑰。")
                    .foregroundStyle(.secondary)

                SecureField("同步密語", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                if mode.requiresConfirmation {
                    SecureField("再次輸入同步密語", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                }

                if mode.requiresConfirmation, !confirmation.isEmpty, passphrase != confirmation {
                    Label("兩次輸入的同步密語不相同。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("至少 12 個字元，區分大小寫，可使用空格與特殊符號。密語只在這台 Mac 處理，不會傳到雲端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .working(let message):
            progress(message)

        case .completed(let recoveryKey):
            VStack(alignment: .leading, spacing: 14) {
                Label("跨裝置同步已成功啟用", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("MyTerm 已完成保管庫、雲端封套、首次資料合併、密碼同步與回讀驗證。之後會在本機變更、App 回到前景及定期檢查時自動同步。")
                    .foregroundStyle(.secondary)

                if let recoveryKey {
                    Text("請保存這把一次性復原金鑰")
                        .font(.headline)
                    Text(recoveryKey)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    Toggle("我已確認復原金鑰保存完整。", isOn: $recoveryKeySaved)
                        .toggleStyle(.checkbox)
                    Text("復原金鑰只顯示這一次，不會自動複製或上傳。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("同步尚未啟用", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("開關仍保持關閉，MyTerm 沒有把未驗證的設定視為同步成功。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.headline)
            }
            Text("這段流程會在背景自動完成，請先不要關閉視窗。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch setupStore.state {
            case .awaitingPassphrase:
                Button("取消", role: .cancel) {
                    clearSensitiveInput()
                    setupStore.reset()
                    dismiss()
                }
                Spacer()
                Button("啟用同步") {
                    let submitted = passphrase
                    clearSensitiveInput()
                    setupStore.activate(
                        passphrase: submitted,
                        hostStore: hostStore,
                        settings: settings,
                        accountStore: accountStore,
                        vaultSetupStore: vaultSetupStore
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!passphraseIsValid)

            case .completed(let recoveryKey):
                Spacer()
                Button("完成") {
                    setupStore.reset()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(recoveryKey != nil && !recoveryKeySaved)

            case .failed:
                Button("取消", role: .cancel) {
                    setupStore.reset()
                    dismiss()
                }
                Spacer()
                Button("重新開始") {
                    clearSensitiveInput()
                    setupStore.reset()
                    setupStore.prepare(accountStore: accountStore)
                }
                .buttonStyle(.borderedProminent)

            default:
                Spacer()
            }
        }
    }

    private func clearSensitiveInput() {
        passphrase = ""
        confirmation = ""
    }
}

private enum VaultUnlockMethod: String, Identifiable {
    case passphrase
    case recoveryKey

    var id: String { rawValue }
    var title: String {
        switch self {
        case .passphrase: "使用同步密語還原"
        case .recoveryKey: "使用復原金鑰還原"
        }
    }
    var fieldTitle: String {
        switch self {
        case .passphrase: "同步密語"
        case .recoveryKey: "MYTERM-R1-…"
        }
    }
}

private struct VaultUnlockView: View {
    @Environment(\.dismiss) private var dismiss
    let method: VaultUnlockMethod
    let onRestore: (String) -> Void
    @State private var value = ""

    private var isValid: Bool {
        switch method {
        case .passphrase: value.count >= 12
        case .recoveryKey: value.hasPrefix("MYTERM-R1-") && value.count > 30
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(method.title)
                    .font(.title2.weight(.semibold))
                Text("驗證與解密只會在這台 Mac 執行；輸入內容不會傳到雲端。")
                    .foregroundStyle(.secondary)
            }

            if method == .passphrase {
                SecureField(method.fieldTitle, text: $value)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(method.fieldTitle, text: $value, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            Label("輸入錯誤時不會建立或覆蓋 Keychain 主金鑰，也不會修改主機資料。", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("驗證並還原") {
                    let submittedValue = value
                    value = ""
                    onRestore(submittedValue)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 540, height: 300)
    }
}

private struct VaultCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    let onCreate: (String) -> Void

    private var isValid: Bool {
        passphrase.count >= 12 && passphrase == confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("建立端對端加密保管庫")
                    .font(.title2.weight(.semibold))
                Text("同步密語只在這台 Mac 用來封裝主金鑰，不會傳到雲端。")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("同步密語", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                    SecureField("再次輸入同步密語", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                    if !confirmation.isEmpty && passphrase != confirmation {
                        Label("兩次輸入的同步密語不相同。", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("至少 12 個字元；建議使用 5 個以上彼此無關且容易記住的詞。遺失密語與復原金鑰後，任何人都無法替你解密。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            Label("建立後會顯示一把復原金鑰。MyTerm 不會自動複製、上傳或存入 iCloud Drive。", systemImage: "key.horizontal")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("建立保管庫") {
                    let submittedPassphrase = passphrase
                    passphrase = ""
                    confirmation = ""
                    onCreate(submittedPassphrase)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 540, height: 390)
    }
}

private struct RecoveryKeyView: View {
    let recoveryKey: String
    let onConfirm: () -> Void
    let onDefer: () -> Void
    @State private var confirmedSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("保存復原金鑰")
                    .font(.title2.weight(.semibold))
                Text("這是加入另一台 Mac 或忘記同步密語時的最後復原方式，只顯示這一次。")
                    .foregroundStyle(.secondary)
            }

            Text(recoveryKey)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("MyTerm 復原金鑰")

            Label("請保存至離線或你信任的位置。MyTerm 不會自動把它放進剪貼簿或任何雲端服務。", systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("我已確認復原金鑰保存完整，且知道遺失後無法由伺服器救回。", isOn: $confirmedSaved)
                .toggleStyle(.checkbox)

            Spacer()
            HStack {
                Button("尚未保存，稍後重新產生") { onDefer() }
                Spacer()
                Button("完成") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!confirmedSaved)
            }
        }
        .padding(24)
        .frame(width: 620, height: 410)
        .interactiveDismissDisabled()
    }
}

private struct ShortcutRecorderView: View {
    let action: AppShortcutAction
    @ObservedObject var shortcutStore: AppShortcutStore
    @Environment(\.dismiss) private var dismiss
    @State private var eventMonitor: Any?
    @State private var recordingWindowNumber: Int?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("設定「\(action.title)」")
                    .font(.title2.bold())
                Text("請直接按下新的快捷鍵組合")
                    .foregroundStyle(.secondary)
            }

            Text(shortcutStore.shortcut(for: action)?.displayText ?? "目前已停用")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else {
                Text("組合必須包含 ⌘、⌥ 或 ⌃。按 Delete 停用，按 Esc 取消。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 450, height: 310)
        .onAppear { installRecorder() }
        .onDisappear { removeRecorder() }
    }

    private func installRecorder() {
        removeRecorder()
        DispatchQueue.main.async {
            recordingWindowNumber = NSApp.keyWindow?.windowNumber
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.windowNumber == recordingWindowNumber else { return event }
                if event.keyCode == 53 {
                    dismiss()
                    return nil
                }
                if event.keyCode == 51 || event.keyCode == 117 {
                    try? shortcutStore.assign(nil, to: action)
                    dismiss()
                    return nil
                }
                guard let shortcut = AppShortcutDefinition(event: event) else {
                    errorMessage = "請按下包含 ⌘、⌥ 或 ⌃ 的快捷鍵組合。"
                    return nil
                }
                do {
                    try shortcutStore.assign(shortcut, to: action)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
                return nil
            }
        }
    }

    private func removeRecorder() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private enum HostSelectionMode: String, CaseIterable, Identifiable {
    case all
    case custom

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部主機"
        case .custom: "自訂選擇"
        }
    }
}

private struct ImportPreviewView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss
    let payload: HostImportPayload
    let onComplete: (String) -> Void
    @State private var selectionMode: HostSelectionMode = .all
    @State private var selectedHostIndexes: Set<Int>
    @State private var hostSearch = ""
    @State private var duplicatePolicy: HostImportDuplicatePolicy = .skipExisting
    @State private var preview: HostImportMergeResult?
    @State private var errorMessage: String?
    @State private var isImporting = false

    init(payload: HostImportPayload, onComplete: @escaping (String) -> Void) {
        self.payload = payload
        self.onComplete = onComplete
        _selectedHostIndexes = State(initialValue: Set(payload.hosts.indices))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("確認匯入")
                        .font(.title2.bold())
                    Text("來源：\(payload.format.title) · \(payload.sourceDescription)")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("匯入範圍", selection: $selectionMode) {
                    ForEach(HostSelectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if selectionMode == .custom {
                    customHostSelection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text("預設匯入檔案內的全部主機。切換到「自訂選擇」即可先做小範圍測試。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    metricRow("來源主機", value: payload.hosts.count)
                    if selectionMode == .custom {
                        metricRow("已選主機", value: activePayload.hosts.count)
                    }
                    metricRow("將匯入", value: preview?.importedHostCount ?? 0)
                    metricRow("將新增群組", value: preview?.addedGroupCount ?? 0)
                    metricRow("將跳過重複", value: preview?.skippedDuplicateCount ?? 0)
                    if (preview?.invalidHostCount ?? 0) > 0 {
                        metricRow("無效主機", value: preview?.invalidHostCount ?? 0)
                    }
                }
                .padding(4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("遇到相同連線時", selection: $duplicatePolicy) {
                    ForEach(HostImportDuplicatePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                Text(duplicatePolicy.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label("此檔案不會帶入密碼。匯入後首次連線時可輸入並儲存至本機 Keychain。", systemImage: "lock.shield")
                .font(.callout)
            if activePayload.referencedPrivateKeyCount > 0 {
                Label("所選主機中有 \(activePayload.referencedPrivateKeyCount) 台原本參照私鑰，將改用 SSH Agent／SSH Config。", systemImage: "key.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let preview, !preview.issues.isEmpty {
                DisclosureGroup("查看無效項目") {
                    ForEach(preview.issues, id: \.self) { issue in
                        Text(issue).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button("匯入") { applyImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || ((preview?.importedHostCount ?? 0) == 0 && (preview?.addedGroupCount ?? 0) == 0))
            }
        }
        .padding(24)
        .frame(width: 680, height: selectionMode == .custom ? 700 : 590)
        .animation(.easeInOut(duration: 0.18), value: selectionMode)
        .onAppear { refreshPreview() }
        .onChange(of: duplicatePolicy) { _, _ in refreshPreview() }
        .onChange(of: selectionMode) { _, _ in refreshPreview() }
        .onChange(of: selectedHostIndexes) { _, _ in
            if selectionMode == .custom { refreshPreview() }
        }
    }

    private var activePayload: HostImportPayload {
        switch selectionMode {
        case .all:
            payload
        case .custom:
            payload.selectingHostIndices(selectedHostIndexes)
        }
    }

    private var filteredHostIndexes: [Int] {
        let query = hostSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(payload.hosts.indices) }
        return payload.hosts.indices.filter { index in
            let host = payload.hosts[index]
            return host.name.localizedCaseInsensitiveContains(query)
                || host.hostname.localizedCaseInsensitiveContains(query)
                || host.username.localizedCaseInsensitiveContains(query)
                || payload.groupPath(forHostAt: index).localizedCaseInsensitiveContains(query)
        }
    }

    private var customHostSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜尋名稱、位址、使用者或群組", text: $hostSearch)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("已選 \(selectedHostIndexes.count)／\(payload.hosts.count) 台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部選取") {
                    selectedHostIndexes = Set(payload.hosts.indices)
                }
                .disabled(selectedHostIndexes.count == payload.hosts.count)
                Button("全部取消") {
                    selectedHostIndexes.removeAll()
                }
                .disabled(selectedHostIndexes.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredHostIndexes.isEmpty {
                        ContentUnavailableView("找不到主機", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(filteredHostIndexes, id: \.self) { index in
                            hostSelectionRow(index: index)
                            if index != filteredHostIndexes.last { Divider() }
                        }
                    }
                }
            }
            .frame(height: 165)
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.secondary.opacity(0.2), lineWidth: 1)
            }
        }
    }

    private func hostSelectionRow(index: Int) -> some View {
        let host = payload.hosts[index]
        let title = host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? host.hostname
            : host.name
        let address = host.username.isEmpty
            ? "\(host.hostname):\(host.port)"
            : "\(host.username)@\(host.hostname):\(host.port)"
        return Toggle(isOn: Binding(
            get: { selectedHostIndexes.contains(index) },
            set: { selected in
                if selected {
                    selectedHostIndexes.insert(index)
                } else {
                    selectedHostIndexes.remove(index)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text("\(address) · \(payload.groupPath(forHostAt: index))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 7)
    }

    private func metricRow(_ title: String, value: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).fontWeight(.semibold)
        }
    }

    private func refreshPreview() {
        do {
            preview = try hostStore.previewImport(activePayload, duplicatePolicy: duplicatePolicy)
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func applyImport() {
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try hostStore.applyImport(activePayload, duplicatePolicy: duplicatePolicy)
            onComplete("已匯入 \(result.merge.importedHostCount) 台主機、建立 \(result.merge.addedGroupCount) 個群組；跳過 \(result.merge.skippedDuplicateCount) 筆重複資料。")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
