import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var knownHostsStore: KnownHostsStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var shortcutStore: AppShortcutStore
    @State private var hostEditorRequest: HostEditorRequest?
    @State private var groupEditorRequest: GroupEditorRequest?
    @State private var connectionRequest: ConnectionRequest?
    @State private var showingSerialConnection = false
    @State private var deleteCandidate: HostProfile?
    @State private var deleteGroupCandidate: HostGroup?
    @State private var libraryWorkspace: LibraryWorkspace = .hosts

    var body: some View {
        VStack(spacing: 0) {
            workspaceTabBar
            Divider()
            workspaceContent
        }
        .sheet(item: $hostEditorRequest) { request in
            HostEditorView(profile: request.profile, defaultGroupID: request.defaultGroupID)
                .environmentObject(hostStore)
        }
        .sheet(item: $groupEditorRequest) { request in
            GroupEditorView(group: request.group, defaultParentID: request.defaultParentID)
                .environmentObject(hostStore)
        }
        .sheet(item: $connectionRequest) { request in
            ConnectionUsernameView(host: request.host, initialUsername: request.initialUsername) { username in
                try openSession(for: request.host, username: username)
            }
        }
        .sheet(isPresented: $showingSerialConnection) {
            SerialConnectionView { configuration in
                try sessionManager.createSerialSession(configuration: configuration)
            }
        }
        .confirmationDialog(
            "刪除主機？",
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除主機與本機密碼", role: .destructive) {
                if let deleteCandidate {
                    do { try hostStore.delete(deleteCandidate) }
                    catch { hostStore.lastError = error.localizedDescription }
                }
                deleteCandidate = nil
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("主機資料及其 Keychain 密碼會一併刪除。")
        }
        .confirmationDialog(
            "刪除群組？",
            isPresented: Binding(get: { deleteGroupCandidate != nil }, set: { if !$0 { deleteGroupCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除群組", role: .destructive) {
                if let deleteGroupCandidate {
                    do { try hostStore.deleteGroup(deleteGroupCandidate) }
                    catch { hostStore.lastError = error.localizedDescription }
                }
                deleteGroupCandidate = nil
            }
            Button("取消", role: .cancel) { deleteGroupCandidate = nil }
        } message: {
            Text("群組內的主機與子群組不會被刪除，會提升到上一層。")
        }
        .alert("發生錯誤", isPresented: errorBinding) {
            Button("好") { hostStore.lastError = nil; knownHostsStore.lastError = nil; sessionManager.lastError = nil }
        } message: {
            Text(hostStore.lastError ?? knownHostsStore.lastError ?? sessionManager.lastError ?? "未知錯誤")
        }
        .alert("注意", isPresented: noticeBinding) {
            Button("好") { hostStore.lastNotice = nil }
        } message: {
            Text(hostStore.lastNotice ?? "")
        }
        .background {
            AppShortcutMonitorView(
                shortcutStore: shortcutStore,
                perform: performShortcut,
                shouldSuppressManagedDefaults: { sessionManager.selectedSession != nil }
            )
            .frame(width: 0, height: 0)
        }
    }

    private var workspaceTabBar: some View {
        HStack(spacing: 7) {
            Button {
                libraryWorkspace = .hosts
                sessionManager.showHostLibrary()
            } label: {
                Label("主機", systemImage: "server.rack")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(tabBackground(isSelected: sessionManager.selectedSessionID == nil && libraryWorkspace == .hosts))
                    .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Divider().frame(height: 24)

            Button {
                libraryWorkspace = .sftp
                sessionManager.showHostLibrary()
            } label: {
                Label("SFTP", systemImage: "folder.fill")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(tabBackground(isSelected: sessionManager.selectedSessionID == nil && libraryWorkspace == .sftp))
                    .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Divider().frame(height: 24)

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(sessionManager.sessions) { session in
                        HStack(spacing: 6) {
                            Button {
                                sessionManager.selectedSessionID = session.id
                            } label: {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(statusColor(session.state))
                                        .frame(width: 7, height: 7)
                                    Image(systemName: sessionSymbol(session.kind))
                                    Text(session.displayName).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                sessionManager.close(session)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.semibold))
                                    .padding(3)
                            }
                            .buttonStyle(.plain)
                            .help("關閉工作階段")
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .padding(.vertical, 7)
                        .background(tabBackground(isSelected: sessionManager.selectedSessionID == session.id))
                        .clipShape(.rect(cornerRadius: 8))
                    }
                }
            }
            .scrollIndicators(.hidden)

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var workspaceContent: some View {
        ZStack {
            HostLibraryView(
                onAddHost: addHost,
                onAddGroup: { parentID in
                    groupEditorRequest = GroupEditorRequest(group: nil, defaultParentID: parentID)
                },
                onEditHost: edit,
                onConnectHost: beginConnection,
                onConnectOtherAccount: askForUsername,
                onDeleteHost: { deleteCandidate = $0 },
                onRenameGroup: {
                    groupEditorRequest = GroupEditorRequest(group: $0, defaultParentID: nil)
                },
                onDeleteGroup: { deleteGroupCandidate = $0 },
                onOpenLocalTerminal: { sessionManager.createLocalSession() },
                onOpenSerial: { showingSerialConnection = true }
            )
            .opacity(sessionManager.selectedSessionID == nil && libraryWorkspace == .hosts ? 1 : 0)
            .allowsHitTesting(sessionManager.selectedSessionID == nil && libraryWorkspace == .hosts)

            SFTPWorkspaceView {
                libraryWorkspace = .hosts
            }
                .opacity(sessionManager.selectedSessionID == nil && libraryWorkspace == .sftp ? 1 : 0)
                .allowsHitTesting(sessionManager.selectedSessionID == nil && libraryWorkspace == .sftp)

            ForEach(sessionManager.sessions) { session in
                TerminalWorkspaceView(
                    session: session,
                    isActive: sessionManager.selectedSessionID == session.id,
                    onClose: { sessionManager.close(session) }
                )
                .opacity(sessionManager.selectedSessionID == session.id ? 1 : 0)
                .allowsHitTesting(sessionManager.selectedSessionID == session.id)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { hostStore.lastError != nil || knownHostsStore.lastError != nil || sessionManager.lastError != nil },
            set: { if !$0 { hostStore.lastError = nil; knownHostsStore.lastError = nil; sessionManager.lastError = nil } }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { hostStore.lastNotice != nil },
            set: { if !$0 { hostStore.lastNotice = nil } }
        )
    }

    private func tabBackground(isSelected: Bool) -> some ShapeStyle {
        isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(0.055))
    }

    private func statusColor(_ state: SessionState) -> Color {
        switch state {
        case .connecting: .yellow
        case .connected: .green
        case .disconnected: .secondary
        case .failed: .red
        }
    }

    private func sessionSymbol(_ kind: TerminalSessionKind) -> String {
        switch kind {
        case .ssh: "network"
        case .local: "terminal.fill"
        case .serial: "cable.connector"
        }
    }

    private func addHost(defaultGroupID: UUID?) {
        hostEditorRequest = HostEditorRequest(profile: nil, defaultGroupID: defaultGroupID)
    }

    private func edit(_ host: HostProfile) {
        hostEditorRequest = HostEditorRequest(profile: host, defaultGroupID: nil)
    }

    private func beginConnection(to host: HostProfile) {
        if host.username.isEmpty { askForUsername(for: host) }
        else {
            do { try openSession(for: host, username: host.username) }
            catch { sessionManager.lastError = error.localizedDescription }
        }
    }

    private func askForUsername(for host: HostProfile) {
        connectionRequest = ConnectionRequest(host: host, initialUsername: "")
    }

    private func openSession(for host: HostProfile, username: String) throws {
        try sessionManager.createSSHSession(to: host, username: username)
    }

    private func performShortcut(_ action: AppShortcutAction) -> Bool {
        switch action {
        case .copyTerminal:
            guard let session = sessionManager.selectedSession else { return false }
            session.copyTerminalSelection()
        case .pasteTerminal:
            guard let session = sessionManager.selectedSession else { return false }
            session.pasteClipboardToTerminal()
        case .pasteSavedPassword:
            guard let session = sessionManager.selectedSession else { return false }
            session.sendSavedPassword()
        case .selectAllTerminal:
            guard let session = sessionManager.selectedSession else { return false }
            session.selectAllTerminalContent()
        case .openHosts:
            libraryWorkspace = .hosts
            sessionManager.showHostLibrary()
        case .openLocalTerminal:
            sessionManager.createLocalSession()
        case .openSerial:
            showingSerialConnection = true
        case .closeTab:
            return sessionManager.closeSelectedSession()
        case .nextTab:
            return sessionManager.selectAdjacentSession(offset: 1)
        case .previousTab:
            return sessionManager.selectAdjacentSession(offset: -1)
        case .findTerminal:
            guard let session = sessionManager.selectedSession else { return false }
            session.showTerminalFind()
        case .disconnectSession:
            guard let session = sessionManager.selectedSession else { return false }
            session.disconnect()
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            guard let index = action.tabIndex else { return false }
            return sessionManager.selectSession(at: index)
        }
        return true
    }
}

private enum LibraryWorkspace {
    case hosts
    case sftp
}

private struct AppShortcutMonitorView: NSViewRepresentable {
    @ObservedObject var shortcutStore: AppShortcutStore
    let perform: (AppShortcutAction) -> Bool
    let shouldSuppressManagedDefaults: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shortcutStore: shortcutStore,
            perform: perform,
            shouldSuppressManagedDefaults: shouldSuppressManagedDefaults
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shortcutStore = shortcutStore
        context.coordinator.perform = perform
        context.coordinator.shouldSuppressManagedDefaults = shouldSuppressManagedDefaults
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var shortcutStore: AppShortcutStore
        var perform: (AppShortcutAction) -> Bool
        var shouldSuppressManagedDefaults: () -> Bool
        weak var hostView: NSView?
        private var monitor: Any?

        init(
            shortcutStore: AppShortcutStore,
            perform: @escaping (AppShortcutAction) -> Bool,
            shouldSuppressManagedDefaults: @escaping () -> Bool
        ) {
            self.shortcutStore = shortcutStore
            self.perform = perform
            self.shouldSuppressManagedDefaults = shouldSuppressManagedDefaults
        }

        func installMonitor() {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.hostView?.window else { return event }
                if let action = self.shortcutStore.action(matching: event) {
                    return self.perform(action) ? nil : event
                }
                if self.shortcutStore.isManagedDefault(event), self.shouldSuppressManagedDefaults() {
                    return nil
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}

private struct TerminalWorkspaceView: View {
    @EnvironmentObject private var hostStore: HostStore
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label(session.detailDescription, systemImage: detailSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(sessionStatusColor).frame(width: 7, height: 7)
                        Text(session.notice ?? session.state.label)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.055), in: .capsule)
                    if session.canUseSavedPassword {
                        Button {
                            session.sendSavedPassword()
                        } label: {
                            Label("填入密碼", systemImage: "key.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!session.canSafelyUseSavedPassword)
                        .help(session.canSafelyUseSavedPassword
                              ? "將 Keychain 密碼送進目前偵測到的密碼提示，不使用剪貼簿"
                              : "只有偵測到密碼提示時才可填入")
                    }
                    Menu {
                        Button("中斷並關閉", role: .destructive) { onClose() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)

                TerminalContainerView(
                    session: session,
                    isActive: isActive,
                    onCloseAfterUserEOF: onClose,
                    onPlatformDetected: recordPlatform
                )
                    .clipShape(.rect(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .alert("儲存這個主機的登入密碼？", isPresented: passwordSaveOfferBinding) {
            Button("儲存到 macOS Keychain") {
                session.saveVerifiedPassword()
            }
            Button("不要儲存", role: .cancel) {
                session.declineVerifiedPassword()
            }
        } message: {
            Text("OpenSSH 已確認剛才輸入的密碼成功登入 \(session.detailDescription)。儲存後，MyTerm 下次可自動登入；密碼只會保存在這台 Mac 的 Keychain。")
        }
    }

    private var passwordSaveOfferBinding: Binding<Bool> {
        Binding(
            get: { session.isOfferingToSavePassword },
            set: { isPresented in
                if !isPresented && session.isOfferingToSavePassword {
                    session.declineVerifiedPassword()
                }
            }
        )
    }

    private var sessionStatusColor: Color {
        switch session.state {
        case .connecting: .orange
        case .connected: .green
        case .disconnected: .secondary
        case .failed: .red
        }
    }

    private var detailSymbol: String {
        switch session.kind {
        case .ssh: "lock.shield"
        case .local: "desktopcomputer"
        case .serial: "cable.connector"
        }
    }

    private func recordPlatform(_ platform: HostPlatform) {
        guard let hostID = session.host?.id else { return }
        do { try hostStore.recordDetectedPlatform(platform, for: hostID) }
        catch { hostStore.lastError = error.localizedDescription }
    }
}

struct GroupEditorRequest: Identifiable {
    let id = UUID()
    let group: HostGroup?
    let defaultParentID: HostGroup.ID?
}

struct ConnectionRequest: Identifiable {
    let id = UUID()
    let host: HostProfile
    let initialUsername: String
}

struct HostEditorRequest: Identifiable {
    let id = UUID()
    let profile: HostProfile?
    let defaultGroupID: UUID?
}
