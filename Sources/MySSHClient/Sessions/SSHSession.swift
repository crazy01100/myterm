import AppKit
import Foundation
import SwiftTerm

enum SessionState: Equatable {
    case connecting
    case connected
    case disconnected(Int32?)
    case failed(String)

    var label: String {
        switch self {
        case .connecting: "連線中"
        case .connected: "已連線"
        case .disconnected(let code): code.map { "已中斷（\($0)）" } ?? "已中斷"
        case .failed(let message): message
        }
    }
}

enum TerminalSessionKind: Equatable {
    case ssh
    case local
    case serial
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let kind: TerminalSessionKind
    let host: HostProfile?
    let username: String?
    let serialConfiguration: SerialConfiguration?
    let executable: String
    let arguments: [String]
    let environment: [String]
    let execName: String
    let currentDirectory: String?
    let authenticationLogURL: URL?
    @Published var state: SessionState = .connecting
    @Published var terminalTitle: String
    @Published var notice: String?
    @Published private(set) var hasSavedPassword = false
    @Published private(set) var isPasswordPromptActive = false
    @Published private(set) var isOfferingToSavePassword = false
    weak var terminalView: LocalProcessTerminalView?
    private var pendingPasswordData: Data?
    private var authenticationLogOffset = 0
    private var authenticationLogDetector = SSHAuthenticationLogDetector()
    private var authenticationMonitorTask: Task<Void, Never>?

    var displayName: String {
        switch kind {
        case .ssh: host?.displayName ?? "SSH"
        case .local: "本地 Terminal"
        case .serial: "Serial"
        }
    }

    var detailDescription: String {
        switch kind {
        case .ssh:
            guard let host, let username else { return "SSH" }
            return "\(username)@\(host.hostname):\(host.port)"
        case .local:
            return "本機 · zsh"
        case .serial:
            guard let serialConfiguration else { return "Serial" }
            return "\(serialConfiguration.devicePath) · \(serialConfiguration.baudRate) bps"
        }
    }

    var canBindPasswordToProfile: Bool {
        guard kind == .ssh, let host, let username else { return false }
        return host.authenticationMethod == .password && !host.username.isEmpty && username == host.username
    }

    var canUseSavedPassword: Bool {
        canBindPasswordToProfile && hasSavedPassword
    }

    var canCapturePasswordForSaving: Bool {
        canBindPasswordToProfile && !hasSavedPassword && authenticationLogURL != nil
    }

    var canSafelyUseSavedPassword: Bool {
        canUseSavedPassword && isPasswordPromptActive && terminalView != nil
    }

    init(host: HostProfile, username: String) throws {
        let username = try HostProfile.validatedUsername(username)
        let canBindPassword = host.authenticationMethod == .password
            && !host.username.isEmpty
            && username == host.username
        let hasSavedPassword = canBindPassword && KeychainStore.containsPassword(for: host.id)
        let authenticationLogURL = canBindPassword && !hasSavedPassword
            ? try AppPaths.createAuthenticationLog()
            : nil
        let arguments: [String]
        do {
            arguments = try SSHArgumentBuilder.arguments(
                for: host,
                usernameOverride: username,
                authenticationLogURL: authenticationLogURL
            )
        } catch {
            AppPaths.removeAuthenticationLog(authenticationLogURL)
            throw error
        }
        kind = .ssh
        self.host = host
        self.username = username
        serialConfiguration = nil
        executable = "/usr/bin/ssh"
        self.arguments = arguments
        environment = SSHEnvironmentBuilder.environment()
        execName = "ssh"
        currentDirectory = nil
        self.authenticationLogURL = authenticationLogURL
        self.hasSavedPassword = hasSavedPassword
        terminalTitle = host.displayName
    }

    init(localShell: Void = ()) {
        kind = .local
        host = nil
        username = nil
        serialConfiguration = nil
        executable = "/bin/zsh"
        arguments = ["-l"]
        environment = LocalTerminalEnvironmentBuilder.environment()
        execName = "zsh"
        currentDirectory = LocalTerminalEnvironmentBuilder.currentDirectory()
        authenticationLogURL = nil
        terminalTitle = "本地 Terminal"
    }

    init(serial configuration: SerialConfiguration) throws {
        let configuration = try configuration.validated()
        try configuration.prepareDevice()
        kind = .serial
        host = nil
        username = nil
        serialConfiguration = configuration
        executable = "/usr/bin/screen"
        arguments = ["-U", configuration.devicePath, configuration.screenMode]
        environment = LocalTerminalEnvironmentBuilder.environment()
        execName = "screen"
        currentDirectory = nil
        authenticationLogURL = nil
        terminalTitle = "Serial"
    }

    func attach(terminal: LocalProcessTerminalView) {
        terminalView = terminal
        state = .connected
    }

    func sendSavedPassword(automatic: Bool = false) {
        guard canUseSavedPassword, let host else {
            notice = "本次帳號沒有綁定可自動使用的密碼。"
            return
        }
        guard isPasswordPromptActive else {
            notice = "未偵測到密碼提示；為保護密碼，MyTerm 已阻止填入。"
            return
        }
        guard let terminalView else {
            notice = "目前沒有可輸入的終端工作階段。"
            return
        }
        do {
            guard var secret = try KeychainStore.passwordData(for: host.id) else {
                notice = "這個主機尚未儲存密碼。"
                return
            }
            var secretBytes = Array(secret)
            secret.resetBytes(in: secret.startIndex..<secret.endIndex)
            secretBytes.append(0x0A)
            isPasswordPromptActive = false
            terminalView.process.send(data: secretBytes[...])
            for index in secretBytes.indices { secretBytes[index] = 0 }
            notice = automatic ? "已使用儲存的密碼登入。" : "密碼已直接送至目前工作階段。"
        } catch {
            notice = error.localizedDescription
        }
    }

    func setPasswordPromptActive(_ isActive: Bool) {
        isPasswordPromptActive = isActive
    }

    func copyTerminalSelection() {
        guard let terminalView else { return }
        terminalView.copy(self)
    }

    func pasteClipboardToTerminal() {
        guard let terminalView else { return }
        terminalView.paste(self)
    }

    func selectAllTerminalContent() {
        guard let terminalView else { return }
        terminalView.selectAll(self)
    }

    func showTerminalFind() {
        guard let terminalView else { return }
        let menuItem = NSMenuItem()
        menuItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminalView.performFindPanelAction(menuItem)
    }

    /// Called for each SSH login password prompt while a profile does not yet
    /// have a saved password. A repeated prompt proves the previous attempt
    /// failed, so that attempt is cleared before capturing the next one.
    func prepareForLoginPasswordEntry() -> Bool {
        guard canCapturePasswordForSaving else { return false }
        clearPendingPassword()
        isOfferingToSavePassword = false
        return true
    }

    func receiveSubmittedLoginPassword(_ submittedData: Data) {
        var submittedData = submittedData
        defer {
            if !submittedData.isEmpty {
                submittedData.resetBytes(in: submittedData.startIndex..<submittedData.endIndex)
            }
        }
        guard canCapturePasswordForSaving, !submittedData.isEmpty else { return }
        clearPendingPassword()
        pendingPasswordData = submittedData
        startAuthenticationMonitor()
    }

    func cancelSubmittedLoginPassword() {
        clearPendingPassword()
        isOfferingToSavePassword = false
    }

    func saveVerifiedPassword() {
        guard isOfferingToSavePassword, let host, var passwordData = pendingPasswordData else { return }
        defer {
            if !passwordData.isEmpty {
                passwordData.resetBytes(in: passwordData.startIndex..<passwordData.endIndex)
            }
            clearPendingPassword()
            isOfferingToSavePassword = false
        }
        do {
            try KeychainStore.save(passwordData: passwordData, for: host.id)
            hasSavedPassword = true
            notice = "密碼已安全儲存至這台 Mac 的加密保管庫。"
        } catch {
            notice = error.localizedDescription
        }
    }

    func declineVerifiedPassword() {
        clearPendingPassword()
        isOfferingToSavePassword = false
        notice = "本次登入密碼未儲存。"
    }

    func authenticationDidEnd() {
        authenticationMonitorTask?.cancel()
        authenticationMonitorTask = nil
        clearPendingPassword()
        isOfferingToSavePassword = false
        isPasswordPromptActive = false
        AppPaths.removeAuthenticationLog(authenticationLogURL)
    }

    private func startAuthenticationMonitor() {
        guard authenticationMonitorTask == nil, authenticationLogURL != nil else { return }
        authenticationMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.inspectAuthenticationLog()
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func inspectAuthenticationLog() {
        guard let authenticationLogURL,
              let data = try? Data(contentsOf: authenticationLogURL) else { return }
        if data.count < authenticationLogOffset {
            authenticationLogOffset = 0
            authenticationLogDetector = SSHAuthenticationLogDetector()
        }
        guard data.count > authenticationLogOffset else { return }
        let newBytes = Array(data[authenticationLogOffset...])
        authenticationLogOffset = data.count
        guard let result = authenticationLogDetector.consume(newBytes[...]) else { return }

        authenticationMonitorTask?.cancel()
        authenticationMonitorTask = nil
        (terminalView as? LoginAwareTerminalView)?.stopLoginPasswordPromptMonitoring()
        AppPaths.removeAuthenticationLog(authenticationLogURL)

        switch result {
        case .password:
            if pendingPasswordData?.isEmpty == false {
                isOfferingToSavePassword = true
                notice = "登入密碼已由 OpenSSH 驗證成功。"
            } else {
                clearPendingPassword()
            }
        case .other(let method):
            clearPendingPassword()
            if method == "keyboard-interactive" {
                notice = "伺服器使用 keyboard-interactive 驗證；為避免誤存一次性密碼，本次不提供儲存。"
            }
        }
    }

    private func clearPendingPassword() {
        guard var pendingPasswordData else { return }
        if !pendingPasswordData.isEmpty {
            pendingPasswordData.resetBytes(in: pendingPasswordData.startIndex..<pendingPasswordData.endIndex)
        }
        self.pendingPasswordData = nil
    }

    func disconnect() {
        isPasswordPromptActive = false
        authenticationDidEnd()
        terminalView?.process.terminate()
        terminalView = nil
    }

    deinit {
        authenticationMonitorTask?.cancel()
        AppPaths.removeAuthenticationLog(authenticationLogURL)
    }
}

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private var workspaceState = TerminalWorkspaceCollection()
    @Published var lastError: String?

    var workspaces: [TerminalWorkspace] {
        workspaceState.workspaces
    }

    var selectedWorkspaceID: TerminalWorkspace.ID? {
        get { workspaceState.selectedWorkspaceID }
        set { _ = workspaceState.selectWorkspace(id: newValue) }
    }

    var selectedSessionID: TerminalSession.ID? {
        get { workspaceState.selectedSessionID }
        set {
            if let newValue {
                _ = workspaceState.activate(sessionID: newValue)
            } else {
                workspaceState.showLibrary()
            }
        }
    }

    var selectedWorkspace: TerminalWorkspace? {
        workspaceState.selectedWorkspace
    }

    var selectedSession: TerminalSession? {
        session(id: selectedSessionID)
    }

    func session(id: TerminalSession.ID?) -> TerminalSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func workspace(id: TerminalWorkspace.ID?) -> TerminalWorkspace? {
        workspaceState.workspace(id: id)
    }

    func sessions(in workspace: TerminalWorkspace) -> [TerminalSession] {
        workspace.sessionIDs.compactMap { session(id: $0) }
    }

    func workspace(containing sessionID: TerminalSession.ID) -> TerminalWorkspace? {
        workspaceState.workspace(containing: sessionID)
    }

    func showHostLibrary() {
        workspaceState.showLibrary()
    }

    @discardableResult
    func createSSHSession(to host: HostProfile, username: String) throws -> TerminalSession.ID {
        let session = try TerminalSession(host: host, username: username)
        sessions.append(session)
        workspaceState.add(sessionID: session.id)
        return session.id
    }

    @discardableResult
    func createLocalSession() -> TerminalSession.ID {
        let session = TerminalSession()
        sessions.append(session)
        workspaceState.add(sessionID: session.id)
        return session.id
    }

    @discardableResult
    func createSerialSession(configuration: SerialConfiguration) throws -> TerminalSession.ID {
        let session = try TerminalSession(serial: configuration)
        sessions.append(session)
        workspaceState.add(sessionID: session.id)
        return session.id
    }

    func close(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        _ = workspaceState.close(sessionID: session.id)
    }

    @discardableResult
    func closeActiveSession(in workspaceID: TerminalWorkspace.ID) -> Bool {
        guard let workspace = workspace(id: workspaceID),
              let session = session(id: workspace.activeSessionID) else { return false }
        close(session)
        return true
    }

    func closeSelectedSession() -> Bool {
        guard let selectedSession else { return false }
        close(selectedSession)
        return true
    }

    func selectSession(at index: Int) -> Bool {
        workspaceState.selectWorkspace(at: index)
    }

    func selectAdjacentSession(offset: Int) -> Bool {
        workspaceState.selectAdjacentWorkspace(offset: offset)
    }

    @discardableResult
    func selectWorkspace(_ workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.selectWorkspace(id: workspaceID)
    }

    @discardableResult
    func activate(sessionID: TerminalSession.ID) -> Bool {
        workspaceState.activate(sessionID: sessionID)
    }

    @discardableResult
    func moveWorkspace(_ workspaceID: TerminalWorkspace.ID, toInsertionIndex index: Int) -> Bool {
        workspaceState.moveWorkspace(id: workspaceID, toInsertionIndex: index)
    }

    @discardableResult
    func mergeWorkspaces(
        sourceWorkspaceID: TerminalWorkspace.ID,
        targetWorkspaceID: TerminalWorkspace.ID,
        position: TerminalWorkspaceDropPosition
    ) -> Bool {
        do {
            try workspaceState.merge(
                sourceWorkspaceID: sourceWorkspaceID,
                targetWorkspaceID: targetWorkspaceID,
                position: position
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func detachSession(_ sessionID: TerminalSession.ID, toInsertionIndex index: Int) -> Bool {
        do {
            try workspaceState.detach(sessionID: sessionID, toInsertionIndex: index)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setSplitAxis(_ splitAxis: TerminalWorkspaceSplitAxis, for workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.setSplitAxis(splitAxis, for: workspaceID)
    }

    @discardableResult
    func toggleSplitAxis(for workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.toggleSplitAxis(for: workspaceID)
    }

    @discardableResult
    func setSplitRatio(_ ratio: Double, for workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.setSplitRatio(ratio, for: workspaceID)
    }

    @discardableResult
    func focusOtherPane() -> Bool {
        workspaceState.focusOtherPane()
    }
}
