import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var knownHostsStore: KnownHostsStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var connectionAuditStore: ConnectionAuditStore
    @EnvironmentObject private var shortcutStore: AppShortcutStore
    @State private var hostEditorRequest: HostEditorRequest?
    @State private var groupEditorRequest: GroupEditorRequest?
    @State private var connectionRequest: ConnectionRequest?
    @State private var showingSerialConnection = false
    @State private var deleteCandidate: HostProfile?
    @State private var deleteGroupCandidate: HostGroup?
    @State private var libraryWorkspace: LibraryWorkspace = .hosts
    @State private var hostLibrarySelection: HostLibrarySelection = .all
    @State private var hostLibraryColumnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var isSidebarToggleHovered = false
    @State private var draggedWorkspaceID: TerminalWorkspace.ID?
    @State private var tabDragOriginalSelectionID: TerminalWorkspace.ID?
    @State private var tabDragInsertionIndex: Int?
    @State private var tabDragProposal: WorkspaceTabDragProposal?
    @State private var workspaceTabFrames: [TerminalWorkspace.ID: CGRect] = [:]
    @State private var workspaceTabBarFrame: CGRect = .zero
    @State private var workspaceContentFrame: CGRect = .zero
    @State private var workspaceMouseDragSource: WorkspaceMouseDragSource?
    @State private var paneDetachInsertionIndex: Int?

    var body: some View {
        workspaceContent
        .toolbar {
            ToolbarItem(placement: .navigation) {
                sidebarToggleButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .automatic) {
                workspaceTabBar
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(AppVisualTheme.chromeBackground, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .onAppear(perform: configureSessionObservers)
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
            Text("主機資料及其本機加密保管庫密碼會一併刪除。")
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
        .overlay {
            AppShortcutMonitorView(
                shortcutStore: shortcutStore,
                hostStore: hostStore,
                perform: performShortcut,
                shouldSuppressManagedDefaults: { sessionManager.selectedSession != nil },
                prepareDrag: prepareWorkspaceMouseDrag,
                beginDrag: beginWorkspaceMouseDrag,
                changeDrag: updateWorkspaceMouseDrag,
                endDrag: finishWorkspaceMouseDrag,
                cancelDrag: cancelWorkspaceMouseDrag
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            hostLibraryColumnVisibility = isHostLibrarySidebarVisible ? .detailOnly : .all
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(AppVisualTheme.chromeForeground)
                .frame(width: 34, height: 30)
                .background(
                    isSidebarToggleHovered
                        ? AppVisualTheme.chromeSelectedSurface
                        : AppVisualTheme.chromeSubtleSurface
                )
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppVisualTheme.chromeSecondary.opacity(0.42), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .onHover { isSidebarToggleHovered = $0 }
        .help(isHostLibrarySidebarVisible ? "隱藏側邊欄" : "顯示側邊欄")
        .accessibilityLabel(isHostLibrarySidebarVisible ? "隱藏側邊欄" : "顯示側邊欄")
    }

    private var isHostLibrarySidebarVisible: Bool {
        hostLibraryColumnVisibility != .detailOnly
    }

    private var workspaceTabBar: some View {
        HStack(spacing: 7) {
            Button {
                libraryWorkspace = .hosts
                hostLibrarySelection = .all
                sessionManager.showHostLibrary()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "server.rack")
                    Text("主機")
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(tabBackground(isSelected: sessionManager.selectedSessionID == nil && libraryWorkspace == .hosts))
                    .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("主機")

            Divider().frame(height: 24)

            Button {
                libraryWorkspace = .sftp
                sessionManager.showHostLibrary()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                    Text("SFTP")
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(tabBackground(isSelected: sessionManager.selectedSessionID == nil && libraryWorkspace == .sftp))
                    .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("SFTP")

            Divider().frame(height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(sessionManager.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceReorderDropZone(
                            insertionIndex: index,
                            isGestureTargeted: activeTabInsertionIndex == index
                        )
                        if let session = sessionManager.session(id: workspace.activeSessionID) {
                            workspaceTab(workspace, activeSession: session)
                        }
                    }
                    WorkspaceReorderDropZone(
                        insertionIndex: sessionManager.workspaces.count,
                        isGestureTargeted: activeTabInsertionIndex == sessionManager.workspaces.count
                    )
                }
            }
            .frame(idealWidth: 720, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

        }
        .padding(.vertical, 4)
        .foregroundStyle(AppVisualTheme.chromeForeground)
    }

    private func workspaceTab(
        _ workspace: TerminalWorkspace,
        activeSession session: TerminalSession
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                sessionManager.selectWorkspace(workspace.id)
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor(session.state))
                        .frame(width: 7, height: 7)
                    if workspace.isSplit {
                        Image(systemName: "rectangle.split.2x1")
                            .frame(width: 18, height: 18)
                        Text("Workspace")
                            .lineLimit(1)
                    } else {
                        TerminalSessionIcon(session: session, size: 18)
                        Text(session.displayName)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Button {
                sessionManager.closeActiveSession(in: workspace.id)
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
        .frame(minWidth: 132, maxWidth: 220, alignment: .leading)
        .background(tabBackground(isSelected: sessionManager.selectedWorkspaceID == workspace.id))
        .clipShape(.rect(cornerRadius: 8))
        .background {
            WindowTopLeftFrameReader { frame in
                if workspaceTabFrames[workspace.id] != frame {
                    workspaceTabFrames[workspace.id] = frame
                }
            }
        }
        .opacity(draggedWorkspaceID == workspace.id ? 0.35 : 1)
        .zIndex(draggedWorkspaceID == workspace.id ? 1 : 0)
    }

    private func updateWorkspaceTabDrag(
        workspaceID: TerminalWorkspace.ID,
        location: CGPoint
    ) -> WorkspaceDragPresentation? {
        if draggedWorkspaceID == nil {
            tabDragOriginalSelectionID = sessionManager.selectedWorkspaceID
            draggedWorkspaceID = workspaceID
        }

        let nextProposal: WorkspaceTabDragProposal?
        if workspaceContentFrame.contains(location),
           sessionManager.workspace(id: workspaceID)?.sessionIDs.count == 1,
           let targetWorkspaceID = sessionManager.preferredMergeTargetID(for: workspaceID) {
            if sessionManager.selectedWorkspaceID != targetWorkspaceID {
                _ = sessionManager.selectWorkspace(targetWorkspaceID)
            }
            nextProposal = .merge(
                targetWorkspaceID: targetWorkspaceID,
                position: dropPosition(at: location, in: workspaceContentFrame)
            )
            if tabDragInsertionIndex != nil { tabDragInsertionIndex = nil }
        } else if workspaceTabBarFrame.contains(location) {
            restoreOriginalSelectionDuringTabDrag()
            let insertionIndex = insertionIndex(for: workspaceID, atX: location.x)
            nextProposal = insertionIndex.map(WorkspaceTabDragProposal.reorder)
            if tabDragInsertionIndex != insertionIndex { tabDragInsertionIndex = insertionIndex }
        } else {
            restoreOriginalSelectionDuringTabDrag()
            nextProposal = nil
            if tabDragInsertionIndex != nil { tabDragInsertionIndex = nil }
        }
        if tabDragProposal != nextProposal { tabDragProposal = nextProposal }

        guard let workspace = sessionManager.workspace(id: workspaceID),
              let session = sessionManager.session(id: workspace.activeSessionID) else { return nil }
        return WorkspaceDragPresentation(
            session: session,
            title: workspace.isSplit ? "Workspace" : session.displayName,
            isWorkspace: workspace.isSplit,
            location: location,
            previewPosition: nextProposal?.mergePosition,
            previewFrame: workspaceContentFrame
        )
    }

    private func finishWorkspaceTabDrag(
        workspaceID: TerminalWorkspace.ID,
        location: CGPoint
    ) {
        let finalProposal: WorkspaceTabDragProposal?
        if workspaceContentFrame.contains(location),
           sessionManager.workspace(id: workspaceID)?.sessionIDs.count == 1,
           let targetWorkspaceID = sessionManager.preferredMergeTargetID(for: workspaceID) {
            _ = sessionManager.selectWorkspace(targetWorkspaceID)
            finalProposal = .merge(
                targetWorkspaceID: targetWorkspaceID,
                position: dropPosition(at: location, in: workspaceContentFrame)
            )
        } else if workspaceTabBarFrame.contains(location),
                  let insertionIndex = insertionIndex(for: workspaceID, atX: location.x) {
            finalProposal = .reorder(insertionIndex)
        } else {
            finalProposal = tabDragProposal
        }

        var completedMerge = false
        switch finalProposal {
        case .reorder(let insertionIndex):
            restoreOriginalSelectionDuringTabDrag()
            _ = sessionManager.moveWorkspace(workspaceID, toInsertionIndex: insertionIndex)
        case .merge(let targetWorkspaceID, let position):
            completedMerge = sessionManager.mergeWorkspaces(
                sourceWorkspaceID: workspaceID,
                targetWorkspaceID: targetWorkspaceID,
                position: position
            )
        case nil:
            break
        }
        if !completedMerge {
            restoreOriginalSelectionDuringTabDrag()
        }
        draggedWorkspaceID = nil
        tabDragOriginalSelectionID = nil
        tabDragInsertionIndex = nil
        tabDragProposal = nil
    }

    private func dropPosition(at location: CGPoint, in frame: CGRect) -> TerminalWorkspaceDropPosition {
        guard frame.width > 0, frame.height > 0 else { return .right }
        let localX = location.x - frame.minX
        let localY = location.y - frame.minY
        let horizontalEdgeDistance = min(localX, frame.width - localX) / frame.width
        let verticalEdgeDistance = min(localY, frame.height - localY) / frame.height
        if horizontalEdgeDistance < verticalEdgeDistance {
            return localX < frame.width / 2 ? .left : .right
        }
        return localY < frame.height / 2 ? .top : .bottom
    }

    private func restoreOriginalSelectionDuringTabDrag() {
        guard let tabDragOriginalSelectionID else { return }
        if sessionManager.selectedWorkspaceID != tabDragOriginalSelectionID {
            _ = sessionManager.selectWorkspace(tabDragOriginalSelectionID)
        }
    }

    private func insertionIndex(
        for workspaceID: TerminalWorkspace.ID,
        atX xPosition: CGFloat
    ) -> Int? {
        guard let sourceIndex = sessionManager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return nil
        }
        let remaining = sessionManager.workspaces.filter { $0.id != workspaceID }
        var finalIndex = remaining.count
        for (index, workspace) in remaining.enumerated() {
            guard let frame = workspaceTabFrames[workspace.id] else { continue }
            if xPosition < frame.midX {
                finalIndex = index
                break
            }
        }
        return finalIndex + (sourceIndex < finalIndex ? 1 : 0)
    }

    private var activeTabInsertionIndex: Int? {
        paneDetachInsertionIndex ?? tabDragInsertionIndex
    }

    private func updatePaneDrag(
        sessionID: TerminalSession.ID,
        location: CGPoint
    ) -> WorkspaceDragPresentation? {
        guard sessionManager.workspace(containing: sessionID)?.isSplit == true,
              let session = sessionManager.session(id: sessionID) else { return nil }
        let nextInsertionIndex = workspaceTabBarFrame.contains(location)
            ? detachedPaneInsertionIndex(atX: location.x)
            : nil
        if paneDetachInsertionIndex != nextInsertionIndex {
            paneDetachInsertionIndex = nextInsertionIndex
        }
        return WorkspaceDragPresentation(
            session: session,
            title: session.displayName,
            isWorkspace: false,
            location: location,
            previewPosition: nil,
            previewFrame: .zero
        )
    }

    private func finishPaneDrag(sessionID: TerminalSession.ID, location: CGPoint) {
        let finalInsertionIndex = workspaceTabBarFrame.contains(location)
            ? detachedPaneInsertionIndex(atX: location.x)
            : paneDetachInsertionIndex
        if let finalInsertionIndex {
            _ = sessionManager.detachSession(sessionID, toInsertionIndex: finalInsertionIndex)
        }
        paneDetachInsertionIndex = nil
    }

    private func beginWorkspaceMouseDrag(at location: CGPoint) -> Bool {
        if let workspaceID = sessionManager.workspaces
            .first(where: { workspaceTabFrames[$0.id]?.contains(location) == true })?.id {
            workspaceMouseDragSource = .workspace(workspaceID)
            tabDragOriginalSelectionID = sessionManager.selectedWorkspaceID
            return true
        }

        if let workspace = sessionManager.selectedWorkspace, workspace.isSplit,
           let sessionID = workspace.sessionIDs
            .first(where: { workspacePaneHeaderFrame(for: $0, in: workspace)?.contains(location) == true }) {
            workspaceMouseDragSource = .pane(sessionID)
            return true
        }
        workspaceMouseDragSource = nil
        return false
    }

    private func prepareWorkspaceMouseDrag(in rootBounds: CGRect) {
        workspaceTabBarFrame = CGRect(
            x: rootBounds.minX,
            y: rootBounds.minY,
            width: rootBounds.width,
            height: max(
                workspaceTabFrames.values.map(\.maxY).max().map { $0 + 8 } ?? 50,
                50
            )
        )
    }

    private func workspacePaneHeaderFrame(
        for sessionID: TerminalSession.ID,
        in workspace: TerminalWorkspace
    ) -> CGRect? {
        guard let paneFrame = terminalFrame(
            for: sessionID,
            workspace: workspace,
            in: workspaceContentFrame.size
        ) else { return nil }
        return CGRect(
            x: workspaceContentFrame.minX + paneFrame.minX,
            y: workspaceContentFrame.minY + paneFrame.minY,
            width: paneFrame.width,
            height: min(48, paneFrame.height)
        )
    }

    private func updateWorkspaceMouseDrag(at location: CGPoint) -> WorkspaceDragPresentation? {
        switch workspaceMouseDragSource {
        case .workspace(let workspaceID):
            updateWorkspaceTabDrag(workspaceID: workspaceID, location: location)
        case .pane(let sessionID):
            updatePaneDrag(sessionID: sessionID, location: location)
        case nil:
            nil
        }
    }

    private func finishWorkspaceMouseDrag(at location: CGPoint) {
        switch workspaceMouseDragSource {
        case .workspace(let workspaceID):
            finishWorkspaceTabDrag(workspaceID: workspaceID, location: location)
        case .pane(let sessionID):
            finishPaneDrag(sessionID: sessionID, location: location)
        case nil:
            break
        }
        workspaceMouseDragSource = nil
    }

    private func cancelWorkspaceMouseDrag() {
        workspaceMouseDragSource = nil
        restoreOriginalSelectionDuringTabDrag()
        draggedWorkspaceID = nil
        tabDragOriginalSelectionID = nil
        tabDragInsertionIndex = nil
        tabDragProposal = nil
        paneDetachInsertionIndex = nil
    }

    private func detachedPaneInsertionIndex(atX xPosition: CGFloat) -> Int {
        for (index, workspace) in sessionManager.workspaces.enumerated() {
            guard let frame = workspaceTabFrames[workspace.id] else { continue }
            if xPosition < frame.midX { return index }
        }
        return sessionManager.workspaces.count
    }

    private var workspaceContent: some View {
        ZStack {
            HostLibraryView(
                selection: $hostLibrarySelection,
                columnVisibility: $hostLibraryColumnVisibility,
                isActive: sessionManager.selectedSessionID == nil && libraryWorkspace == .hosts,
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
                hostLibrarySelection = .all
            }
                .opacity(sessionManager.selectedSessionID == nil && libraryWorkspace == .sftp ? 1 : 0)
                .allowsHitTesting(sessionManager.selectedSessionID == nil && libraryWorkspace == .sftp)

            GeometryReader { geometry in
                ZStack {
                    TerminalWorkspaceSplitContainer(
                        sessions: sessionManager.sessions,
                        selectedWorkspace: sessionManager.selectedWorkspace,
                        hostStore: hostStore,
                        connectionAuditStore: connectionAuditStore,
                        onActivate: { sessionManager.activate(sessionID: $0) },
                        onToggleSplit: { sessionManager.toggleSplitAxis(for: $0) },
                        onClose: { sessionManager.close($0) },
                        onRetry: { sessionManager.retry($0) },
                        onEditHost: edit,
                        onRatioCommitted: { workspaceID, ratio in
                            sessionManager.setSplitRatio(ratio, for: workspaceID)
                        }
                    )

                }
                .coordinateSpace(name: "terminalWorkspaceCanvas")
            }
            .opacity(sessionManager.selectedWorkspaceID == nil ? 0 : 1)
            .allowsHitTesting(sessionManager.selectedWorkspaceID != nil)
        }
        .background {
            WindowTopLeftFrameReader { frame in
                if workspaceContentFrame != frame {
                    workspaceContentFrame = frame
                }
            }
        }
    }

    private func terminalFrame(
        for sessionID: TerminalSession.ID,
        workspace: TerminalWorkspace?,
        in size: CGSize
    ) -> CGRect? {
        guard let workspace,
              let paneIndex = workspace.sessionIDs.firstIndex(of: sessionID) else { return nil }
        guard workspace.isSplit, let splitAxis = workspace.splitAxis else {
            return CGRect(origin: .zero, size: size)
        }

        let dividerThickness = TerminalWorkspaceLayout.dividerThickness
        let ratio = CGFloat(workspace.splitRatio)
        switch splitAxis {
        case .horizontal:
            let availableWidth = max(size.width - dividerThickness, 0)
            let firstWidth = availableWidth * ratio
            if paneIndex == 0 {
                return CGRect(x: 0, y: 0, width: firstWidth, height: size.height)
            }
            return CGRect(
                x: firstWidth + dividerThickness,
                y: 0,
                width: availableWidth - firstWidth,
                height: size.height
            )
        case .vertical:
            let availableHeight = max(size.height - dividerThickness, 0)
            let firstHeight = availableHeight * ratio
            if paneIndex == 0 {
                return CGRect(x: 0, y: 0, width: size.width, height: firstHeight)
            }
            return CGRect(
                x: 0,
                y: firstHeight + dividerThickness,
                width: size.width,
                height: availableHeight - firstHeight
            )
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
        isSelected
            ? AnyShapeStyle(AppVisualTheme.chromeSelectedSurface)
            : AnyShapeStyle(AppVisualTheme.chromeSubtleSurface)
    }

    private func statusColor(_ state: SessionState) -> Color {
        switch state {
        case .connecting: .yellow
        case .connected: .green
        case .disconnected: .secondary
        case .failed: .red
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

    private func configureSessionObservers() {
        let hostStore = hostStore
        sessionManager.onHostConnectionSucceeded = { [weak hostStore] hostID in
            guard let hostStore else { return }
            do {
                try hostStore.recordSuccessfulConnection(for: hostID)
            } catch {
                NSLog("MyTerm host connection recency save failed: %@", error.localizedDescription)
            }
        }
        sessionManager.connectionAuditStore = connectionAuditStore
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
            hostLibrarySelection = .all
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
        case .focusOtherPane:
            return sessionManager.focusOtherPane()
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

private struct TerminalSessionIcon: View {
    @EnvironmentObject private var hostStore: HostStore
    @ObservedObject var session: TerminalSession
    let size: CGFloat

    var body: some View {
        switch session.kind {
        case .ssh:
            if let platform = currentPlatform {
                HostPlatformBadge(platform: platform, size: size)
            } else {
                Image(systemName: "network")
                    .frame(width: size, height: size)
            }
        case .local:
            Image(systemName: "terminal.fill")
                .frame(width: size, height: size)
        case .serial:
            Image(systemName: "cable.connector")
                .frame(width: size, height: size)
        }
    }

    private var currentPlatform: HostPlatform? {
        guard let host = session.host else { return nil }
        return hostStore.profile(id: host.id)?.detectedPlatform ?? host.detectedPlatform
    }
}

private enum WorkspaceTabDragProposal: Equatable {
    case reorder(Int)
    case merge(
        targetWorkspaceID: TerminalWorkspace.ID,
        position: TerminalWorkspaceDropPosition
    )

    var mergePosition: TerminalWorkspaceDropPosition? {
        guard case .merge(_, let position) = self else { return nil }
        return position
    }
}

enum TerminalWorkspaceLayout {
    static let dividerThickness: CGFloat = 6
    static let dividerHitThickness: CGFloat = 12
    static let terminalHorizontalInset: CGFloat = 12
    static let terminalBottomInset: CGFloat = 12
    static let terminalHeaderHeight: CGFloat = 48
    static let focusBorderClearance: CGFloat = 2
}

private struct WorkspaceSplitDropPreview: View {
    let position: TerminalWorkspaceDropPosition
    let isAllowed: Bool

    var body: some View {
        GeometryReader { geometry in
            let terminalFrame = terminalPanelFrame(in: geometry.size)
            let targetFrame = previewFrame(in: terminalFrame)
            RoundedRectangle(cornerRadius: 14)
                .fill(previewColor.opacity(0.30))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(previewColor.opacity(0.85), lineWidth: 2)
                }
                .overlay {
                Image(systemName: previewSymbol)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(previewColor)
                    .padding(8)
                    .background(.regularMaterial, in: .circle)
                }
                .frame(
                    width: targetFrame.width,
                    height: targetFrame.height
                )
                .position(x: targetFrame.midX, y: targetFrame.midY)
        }
    }

    private var previewColor: Color { isAllowed ? .green : .red }

    private var previewSymbol: String {
        switch position {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .top: "arrow.up"
        case .bottom: "arrow.down"
        }
    }

    private func terminalPanelFrame(in size: CGSize) -> CGRect {
        let clearance = TerminalWorkspaceLayout.focusBorderClearance + 1
        let horizontalInset = TerminalWorkspaceLayout.terminalHorizontalInset + clearance
        let topInset = TerminalWorkspaceLayout.terminalHeaderHeight + clearance
        let bottomInset = TerminalWorkspaceLayout.terminalBottomInset + clearance
        return CGRect(
            x: horizontalInset,
            y: topInset,
            width: max(size.width - horizontalInset * 2, 0),
            height: max(size.height - topInset - bottomInset, 0)
        )
    }

    private func previewFrame(in frame: CGRect) -> CGRect {
        switch position {
        case .left:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
}

private struct WorkspaceDragGhost: View {
    @ObservedObject var session: TerminalSession
    let title: String
    let isWorkspace: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isWorkspace {
                Image(systemName: "rectangle.split.2x1")
            } else {
                TerminalSessionIcon(session: session, size: 18)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(AppVisualTheme.raisedSurface, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(AppVisualTheme.separator)
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
    }
}

private struct WorkspaceReorderDropZone: View {
    let insertionIndex: Int
    let isGestureTargeted: Bool

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: 26)
                .opacity(isGestureTargeted ? 1 : 0)
        }
        .frame(width: 7, height: 34)
        .contentShape(.rect)
    }
}

private struct WindowTopLeftFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameReportingNSView {
        let view = FrameReportingNSView(frame: .zero)
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: FrameReportingNSView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrameIfNeeded()
    }

    final class FrameReportingNSView: NSView {
        var onChange: ((CGRect) -> Void)?
        private var lastReportedFrame = CGRect.null

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrameIfNeeded()
        }

        override func layout() {
            super.layout()
            reportFrameIfNeeded()
        }

        func reportFrameIfNeeded() {
            guard let contentView = window?.contentView else { return }
            let frameInContent = convert(bounds, to: contentView)
            let contentBounds = contentView.bounds
            let topLeftFrame = CGRect(
                x: frameInContent.minX - contentBounds.minX,
                y: contentView.isFlipped
                    ? frameInContent.minY - contentBounds.minY
                    : contentBounds.maxY - frameInContent.maxY,
                width: frameInContent.width,
                height: frameInContent.height
            )
            guard topLeftFrame != lastReportedFrame else { return }
            lastReportedFrame = topLeftFrame
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedFrame == topLeftFrame else { return }
                self.onChange?(topLeftFrame)
            }
        }
    }
}

private enum LibraryWorkspace {
    case hosts
    case sftp
}

private enum WorkspaceMouseDragSource {
    case workspace(TerminalWorkspace.ID)
    case pane(TerminalSession.ID)
}

private struct WorkspaceDragPresentation {
    let session: TerminalSession
    let title: String
    let isWorkspace: Bool
    let location: CGPoint
    let previewPosition: TerminalWorkspaceDropPosition?
    let previewFrame: CGRect
}

private struct AppShortcutMonitorView: NSViewRepresentable {
    @ObservedObject var shortcutStore: AppShortcutStore
    let hostStore: HostStore
    let perform: (AppShortcutAction) -> Bool
    let shouldSuppressManagedDefaults: () -> Bool
    let prepareDrag: (CGRect) -> Void
    let beginDrag: (CGPoint) -> Bool
    let changeDrag: (CGPoint) -> WorkspaceDragPresentation?
    let endDrag: (CGPoint) -> Void
    let cancelDrag: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shortcutStore: shortcutStore,
            hostStore: hostStore,
            perform: perform,
            shouldSuppressManagedDefaults: shouldSuppressManagedDefaults,
            prepareDrag: prepareDrag,
            beginDrag: beginDrag,
            changeDrag: changeDrag,
            endDrag: endDrag,
            cancelDrag: cancelDrag
        )
    }

    func makeNSView(context: Context) -> WorkspaceMonitorNSView {
        let view = WorkspaceMonitorNSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: WorkspaceMonitorNSView, context: Context) {
        context.coordinator.shortcutStore = shortcutStore
        context.coordinator.hostStore = hostStore
        context.coordinator.perform = perform
        context.coordinator.shouldSuppressManagedDefaults = shouldSuppressManagedDefaults
        context.coordinator.prepareDrag = prepareDrag
        context.coordinator.beginDrag = beginDrag
        context.coordinator.changeDrag = changeDrag
        context.coordinator.endDrag = endDrag
        context.coordinator.cancelDrag = cancelDrag
    }

    static func dismantleNSView(_ nsView: WorkspaceMonitorNSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
        nsView.clearDragPresentation()
    }

    final class Coordinator {
        var shortcutStore: AppShortcutStore
        var hostStore: HostStore
        var perform: (AppShortcutAction) -> Bool
        var shouldSuppressManagedDefaults: () -> Bool
        var prepareDrag: (CGRect) -> Void
        var beginDrag: (CGPoint) -> Bool
        var changeDrag: (CGPoint) -> WorkspaceDragPresentation?
        var endDrag: (CGPoint) -> Void
        var cancelDrag: () -> Void
        weak var hostView: WorkspaceMonitorNSView?
        private var keyMonitor: Any?
        private var mouseMonitor: Any?
        private var mouseDownPoint: CGPoint?
        private var isTrackingDrag = false
        private var isDragging = false

        init(
            shortcutStore: AppShortcutStore,
            hostStore: HostStore,
            perform: @escaping (AppShortcutAction) -> Bool,
            shouldSuppressManagedDefaults: @escaping () -> Bool,
            prepareDrag: @escaping (CGRect) -> Void,
            beginDrag: @escaping (CGPoint) -> Bool,
            changeDrag: @escaping (CGPoint) -> WorkspaceDragPresentation?,
            endDrag: @escaping (CGPoint) -> Void,
            cancelDrag: @escaping () -> Void
        ) {
            self.shortcutStore = shortcutStore
            self.hostStore = hostStore
            self.perform = perform
            self.shouldSuppressManagedDefaults = shouldSuppressManagedDefaults
            self.prepareDrag = prepareDrag
            self.beginDrag = beginDrag
            self.changeDrag = changeDrag
            self.endDrag = endDrag
            self.cancelDrag = cancelDrag
        }

        func installMonitor() {
            removeMonitor()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.hostView?.window else { return event }
                if let action = self.shortcutStore.action(matching: event) {
                    return self.perform(action) ? nil : event
                }
                if self.shortcutStore.isManagedDefault(event), self.shouldSuppressManagedDefaults() {
                    return nil
                }
                return event
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self, let hostView = self.hostView,
                      let window = hostView.window,
                      event.window === window,
                      let contentView = window.contentView else { return event }
                let pointInContent = contentView.convert(event.locationInWindow, from: nil)
                let point = CGPoint(
                    x: pointInContent.x - contentView.bounds.minX,
                    y: contentView.isFlipped
                        ? pointInContent.y - contentView.bounds.minY
                        : contentView.bounds.maxY - pointInContent.y
                )

                switch event.type {
                case .leftMouseDown:
                    self.prepareDrag(CGRect(origin: .zero, size: contentView.bounds.size))
                    self.mouseDownPoint = point
                    self.isTrackingDrag = self.beginDrag(point)
                    self.isDragging = false
                case .leftMouseDragged:
                    guard self.isTrackingDrag, let mouseDownPoint = self.mouseDownPoint else { return event }
                    let deltaX = point.x - mouseDownPoint.x
                    let deltaY = point.y - mouseDownPoint.y
                    guard self.isDragging || deltaX * deltaX + deltaY * deltaY >= 16 else { return event }
                    self.isDragging = true
                    if let presentation = self.changeDrag(point) {
                        hostView.showDragPresentation(presentation, hostStore: self.hostStore)
                    }
                    return nil
                case .leftMouseUp:
                    if self.isTrackingDrag {
                        if self.isDragging { self.endDrag(point) }
                        else { self.cancelDrag() }
                    }
                    hostView.clearDragPresentation()
                    self.resetMouseDrag()
                default:
                    break
                }
                return event
            }
        }

        func removeMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            hostView?.clearDragPresentation()
            resetMouseDrag()
        }

        private func resetMouseDrag() {
            mouseDownPoint = nil
            isTrackingDrag = false
            isDragging = false
        }

        deinit { removeMonitor() }
    }

    final class WorkspaceMonitorNSView: NSView {
        private var ghostHost: NSHostingView<AnyView>?
        private var previewHost: NSHostingView<AnyView>?
        private var ghostSessionID: TerminalSession.ID?
        private var ghostTitle = ""
        private var ghostIsWorkspace = false
        private var ghostSize = CGSize.zero
        private var previewPosition: TerminalWorkspaceDropPosition?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func showDragPresentation(_ presentation: WorkspaceDragPresentation, hostStore: HostStore) {
            let ghostNeedsUpdate = ghostSessionID != presentation.session.id
                || ghostTitle != presentation.title
                || ghostIsWorkspace != presentation.isWorkspace
            if ghostHost == nil {
                let host = NSHostingView(rootView: AnyView(EmptyView()))
                host.translatesAutoresizingMaskIntoConstraints = true
                addSubview(host)
                ghostHost = host
            }
            if ghostNeedsUpdate, let ghostHost {
                ghostHost.rootView = AnyView(
                    WorkspaceDragGhost(
                        session: presentation.session,
                        title: presentation.title,
                        isWorkspace: presentation.isWorkspace
                    )
                    .environmentObject(hostStore)
                )
                ghostSessionID = presentation.session.id
                ghostTitle = presentation.title
                ghostIsWorkspace = presentation.isWorkspace
                ghostHost.layoutSubtreeIfNeeded()
                ghostSize = ghostHost.fittingSize
            }
            if let ghostHost {
                let localLocation = localPoint(fromWindowTopLeft: presentation.location)
                ghostHost.frame = CGRect(
                    x: localLocation.x - ghostSize.width / 2,
                    y: localLocation.y - ghostSize.height / 2,
                    width: ghostSize.width,
                    height: ghostSize.height
                )
                ghostHost.isHidden = false
            }

            if let position = presentation.previewPosition {
                if previewHost == nil {
                    let host = NSHostingView(rootView: AnyView(EmptyView()))
                    host.translatesAutoresizingMaskIntoConstraints = true
                    addSubview(host, positioned: .below, relativeTo: ghostHost)
                    previewHost = host
                }
                if previewPosition != position, let previewHost {
                    previewHost.rootView = AnyView(
                        WorkspaceSplitDropPreview(position: position, isAllowed: true)
                    )
                    previewPosition = position
                }
                previewHost?.frame = localRect(fromWindowTopLeft: presentation.previewFrame)
                previewHost?.isHidden = false
            } else {
                previewHost?.isHidden = true
                previewPosition = nil
            }
        }

        func clearDragPresentation() {
            ghostHost?.isHidden = true
            previewHost?.isHidden = true
            ghostSessionID = nil
            ghostTitle = ""
            ghostIsWorkspace = false
            ghostSize = .zero
            previewPosition = nil
        }

        private func localPoint(fromWindowTopLeft point: CGPoint) -> CGPoint {
            guard let contentView = window?.contentView else { return point }
            let contentBounds = contentView.bounds
            let pointInContent = CGPoint(
                x: point.x + contentBounds.minX,
                y: contentView.isFlipped
                    ? point.y + contentBounds.minY
                    : contentBounds.maxY - point.y
            )
            let pointInWindow = contentView.convert(pointInContent, to: nil)
            return convert(pointInWindow, from: nil)
        }

        private func localRect(fromWindowTopLeft rect: CGRect) -> CGRect {
            guard let contentView = window?.contentView else { return rect }
            let contentBounds = contentView.bounds
            let rectInContent = CGRect(
                x: rect.minX + contentBounds.minX,
                y: contentView.isFlipped
                    ? rect.minY + contentBounds.minY
                    : contentBounds.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            let rectInWindow = contentView.convert(rectInContent, to: nil)
            return convert(rectInWindow, from: nil)
        }
    }
}

struct TerminalWorkspaceView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var connectionAuditStore: ConnectionAuditStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isActive: Bool
    let workspaceIsSplit: Bool
    let splitAxis: TerminalWorkspaceSplitAxis?
    let paneIndex: Int?
    let onActivate: () -> Void
    let onToggleSplit: () -> Void
    let onClose: () -> Void
    let onRetry: () -> Void
    let onEditHost: () -> Void
    @State private var showsConnectionPanel = true
    @State private var showsConnectionLogs = false

    var body: some View {
        ZStack {
            AppVisualTheme.contentBackground
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        TerminalSessionIcon(session: session, size: 18)
                        Text(session.detailDescription)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(sessionStatusColor).frame(width: 7, height: 7)
                        Text(sessionStatusText)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppVisualTheme.subtleSurface, in: .capsule)
                    if workspaceIsSplit {
                        Button(action: onToggleSplit) {
                            Image(systemName: splitAxis == .horizontal
                                  ? "rectangle.split.1x2"
                                  : "rectangle.split.2x1")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(splitAxis == .horizontal ? "切換為上下分割" : "切換為左右分割")
                    }
                    if session.shouldPresentConnectionExperience && !showsConnectionPanel {
                        Button {
                            showsConnectionPanel = true
                        } label: {
                            Label("連線狀態", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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
                              ? "將本機保管庫密碼送進目前偵測到的密碼提示，不使用剪貼簿"
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
                .contentShape(.rect)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(AppVisualTheme.raisedSurface)

                ZStack {
                    Color(nsColor: TerminalCanvasAppearance.backgroundColor(for: colorScheme))

                    TerminalContainerView(
                        session: session,
                        isVisible: isVisible,
                        isActive: isActive,
                        onCloseAfterUserEOF: onClose,
                        onPlatformDetected: recordPlatform,
                        onActivate: onActivate,
                        onRetry: onRetry
                    )
                    .padding(.horizontal, TerminalCanvasAppearance.horizontalContentInset)
                    .padding(.vertical, TerminalCanvasAppearance.verticalContentInset)

                    if session.shouldPresentConnectionExperience && showsConnectionPanel {
                        SSHConnectionExperienceView(
                            session: session,
                            showsLogs: $showsConnectionLogs,
                            onShowTerminal: { showsConnectionPanel = false },
                            onRetry: onRetry,
                            onEditHost: onEditHost,
                            onClose: onClose
                        )
                        .transition(.opacity)
                    }
                }
                    .clipShape(.rect(cornerRadius: 13))
                    .padding(.horizontal, TerminalWorkspaceLayout.terminalHorizontalInset)
                    .padding(.bottom, TerminalWorkspaceLayout.terminalBottomInset)
            }
        }
        .clipShape(.rect(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    isActive ? AppVisualTheme.activeOutline : AppVisualTheme.inactiveOutline,
                    lineWidth: isActive ? 1.25 : 1
                )
        }
        .padding(panelInsets)
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded(onActivate))
        .onChange(of: session.isPasswordPromptActive) { _, isActive in
            if isActive { showsConnectionPanel = false }
        }
        .onChange(of: session.state) { _, state in
            if case .failed = state { showsConnectionPanel = true }
        }
        .alert(passwordSaveOfferTitle, isPresented: passwordSaveOfferBinding) {
            Button(passwordSaveOfferActionTitle) {
                session.saveVerifiedPassword()
            }
            Button("不要儲存", role: .cancel) {
                session.declineVerifiedPassword()
            }
        } message: {
            Text(passwordSaveOfferMessage)
        }
    }

    private var panelInsets: EdgeInsets {
        guard workspaceIsSplit, let splitAxis, let paneIndex else {
            return EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12)
        }
        return switch (splitAxis, paneIndex) {
        case (.horizontal, 0):
            EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 2)
        case (.horizontal, _):
            EdgeInsets(top: 4, leading: 2, bottom: 12, trailing: 12)
        case (.vertical, 0):
            EdgeInsets(top: 4, leading: 12, bottom: 2, trailing: 12)
        case (.vertical, _):
            EdgeInsets(top: 2, leading: 12, bottom: 12, trailing: 12)
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

    private var passwordSaveOfferTitle: String {
        session.passwordSaveOfferKind == .login
            ? "儲存這個主機的登入密碼？"
            : "更新這個主機的儲存密碼？"
    }

    private var passwordSaveOfferActionTitle: String {
        session.passwordSaveOfferKind == .login
            ? "安全儲存密碼"
            : "安全更新密碼"
    }

    private var passwordSaveOfferMessage: String {
        if session.passwordSaveOfferKind == .changedPassword {
            return "MyTerm 已確認兩次輸入的新密碼一致，且伺服器已回報密碼變更成功。更新後，下次會使用新密碼登入 \(session.detailDescription)；密碼只會寫入這台 Mac 的加密保管庫。"
        }
        if session.passwordSaveOfferKind == .replacementLogin {
            return "OpenSSH 已確認剛才手動輸入的新密碼成功登入 \(session.detailDescription)。更新後，MyTerm 下次會使用這個密碼自動登入；密碼只會寫入這台 Mac 的加密保管庫。"
        }
        return "OpenSSH 已確認剛才輸入的密碼成功登入 \(session.detailDescription)。儲存後，MyTerm 下次可自動登入；密碼會留在這台 Mac 的加密保管庫。"
    }

    private var sessionStatusColor: Color {
        switch session.state {
        case .connecting: .orange
        case .connected: .green
        case .disconnected: .secondary
        case .failed: .red
        }
    }

    private var sessionStatusText: String {
        switch session.state {
        case .connected:
            session.notice ?? session.state.label
        case .connecting, .disconnected, .failed:
            session.state.label
        }
    }

    private func recordPlatform(_ platform: HostPlatform) {
        guard let hostID = session.host?.id else { return }
        connectionAuditStore.recordDetectedPlatform(sessionID: session.id, platform: platform)
        do { try hostStore.recordDetectedPlatform(platform, for: hostID) }
        catch { hostStore.lastError = error.localizedDescription }
    }
}

private struct SSHConnectionExperienceView: View {
    @ObservedObject var session: TerminalSession
    @Binding var showsLogs: Bool
    let onShowTerminal: () -> Void
    let onRetry: () -> Void
    let onEditHost: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            AppVisualTheme.raisedSurface

            ScrollView {
                VStack(spacing: 22) {
                    connectionHeader
                    phaseIndicator

                    if showsLogs {
                        diagnosticLog
                    }

                    if let suggestion = session.connectionFailureSuggestion {
                        Label(suggestion, systemImage: "lightbulb")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 12))
                    }

                    actionButtons
                }
                .frame(maxWidth: 660)
                .padding(.horizontal, 28)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 14) {
            TerminalSessionIcon(session: session, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("SSH \(session.detailDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 18)
            Button(showsLogs ? "隱藏記錄" : "顯示記錄") {
                withAnimation(.easeInOut(duration: 0.18)) { showsLogs.toggle() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var phaseIndicator: some View {
        HStack(spacing: 14) {
            if session.connectionPhase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.connectionPhase.title)
                    .font(.headline)
                if let failure = session.connectionFailure {
                    Text(failure.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(AppVisualTheme.selectedSurface, in: .rect(cornerRadius: 13))
    }

    private var diagnosticLog: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 11) {
                Text("連線摘要")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(session.connectionEvents.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: event.phase == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(event.phase == .failed ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.phase.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(event.message)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("OpenSSH 原始記錄")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("已排除詳細除錯資訊並遮蔽機密")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if session.displayedConnectionTechnicalLines.isEmpty {
                    Text("等待 OpenSSH 回傳連線資訊…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.displayedConnectionTechnicalLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 13))
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button("關閉", role: .cancel, action: onClose)
                .buttonStyle(.bordered)

            Button("查看終端機", action: onShowTerminal)
                .buttonStyle(.bordered)

            Spacer()

            if session.connectionFailure != nil {
                Button {
                    session.copySanitizedConnectionReport()
                } label: {
                    Label("複製記錄", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button("編輯主機", action: onEditHost)
                    .buttonStyle(.bordered)

                Button("重新連線", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
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
