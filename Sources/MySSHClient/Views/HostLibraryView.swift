import AppKit
import SwiftUI

enum HostLibrarySelection: Hashable {
    case all
    case group(UUID)
    case ungrouped
    case knownHosts
    case logs
}

private struct HostGroupMoveRequest: Identifiable {
    let id = UUID()
    let hostID: HostProfile.ID
    let hostName: String
    let sourceGroupName: String
    let targetGroupID: HostGroup.ID?
    let targetGroupName: String
}

private enum HostLibraryDragCoordinateSpace {
    static let name = "host-library-drag"
}

private struct HostGroupCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [HostGroup.ID: CGRect] = [:]

    static func reduce(
        value: inout [HostGroup.ID: CGRect],
        nextValue: () -> [HostGroup.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct HostCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [HostProfile.ID: CGRect] = [:]

    static func reduce(
        value: inout [HostProfile.ID: CGRect],
        nextValue: () -> [HostProfile.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct HostLibraryView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Binding var selection: HostLibrarySelection
    @State private var searchText = ""
    @State private var selectedGroupCardID: HostGroup.ID?
    @State private var targetedDropGroupID: HostGroup.ID?
    @State private var pendingHostMove: HostGroupMoveRequest?
    @State private var groupCardFrames: [HostGroup.ID: CGRect] = [:]
    @State private var hostCardFrames: [HostProfile.ID: CGRect] = [:]
    @State private var draggedHostID: HostProfile.ID?
    @State private var hostDragLocation: CGPoint?

    let isActive: Bool
    let onAddHost: (UUID?) -> Void
    let onAddGroup: (UUID?) -> Void
    let onEditHost: (HostProfile) -> Void
    let onConnectHost: (HostProfile) -> Void
    let onConnectOtherAccount: (HostProfile) -> Void
    let onOpenSFTP: (HostProfile) -> Void
    let onDeleteHost: (HostProfile) -> Void
    let onRenameGroup: (HostGroup) -> Void
    let onDeleteGroup: (HostGroup) -> Void
    let onOpenLocalTerminal: () -> Void
    let onOpenSerial: () -> Void

    private var allFilteredHosts: [HostProfile] {
        let scopedHosts: [HostProfile]
        switch selection {
        case .all: scopedHosts = hostStore.hosts
        case .group(let id):
            if searchText.isEmpty {
                scopedHosts = hostStore.hosts.filter { $0.groupID == id }
            } else {
                let groupIDs = hostStore.descendantGroupIDs(of: id)
                scopedHosts = hostStore.hosts.filter { $0.groupID.map(groupIDs.contains) == true }
            }
        case .ungrouped: scopedHosts = hostStore.hosts.filter { $0.groupID == nil }
        case .knownHosts, .logs: scopedHosts = []
        }
        let filteredHosts = searchText.isEmpty ? scopedHosts : scopedHosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText) ||
            hostStore.groupName(for: $0).localizedCaseInsensitiveContains(searchText)
        }
        return hostStore.hostsByMostRecentConnection(filteredHosts)
    }

    private var visibleGroups: [HostGroup] {
        let baseGroups: [HostGroup]
        switch selection {
        case .all: baseGroups = hostStore.childGroups(of: nil)
        case .group(let id): baseGroups = hostStore.childGroups(of: id)
        case .ungrouped, .knownHosts, .logs: baseGroups = []
        }
        guard !searchText.isEmpty else { return baseGroups }
        return baseGroups.filter { group in
            group.name.localizedCaseInsensitiveContains(searchText) ||
            hostStore.groupPath(for: group.id).localizedCaseInsensitiveContains(searchText) ||
            hostStore.hosts.contains { host in
                let groupIDs = hostStore.descendantGroupIDs(of: group.id)
                return host.groupID.map(groupIDs.contains) == true &&
                    (host.displayName.localizedCaseInsensitiveContains(searchText) ||
                     host.hostname.localizedCaseInsensitiveContains(searchText) ||
                     host.username.localizedCaseInsensitiveContains(searchText))
            }
        }
    }

    private var pageTitle: String {
        switch selection {
        case .all: "所有主機"
        case .group(let id): hostStore.groupPath(for: id)
        case .ungrouped: "未分類"
        case .knownHosts: "Known Hosts"
        case .logs: "Logs"
        }
    }

    private var selectedGroupAncestry: [HostGroup] {
        guard case .group(let id) = selection else { return [] }
        return hostStore.groupAncestry(for: id)
    }

    private var selectedDefaultGroupID: UUID? {
        if case .group(let id) = selection { return id }
        return nil
    }

    var body: some View {
        Group {
            if selection == .knownHosts {
                KnownHostsView(onReturnToHosts: { selection = .all })
            } else if selection == .logs {
                ConnectionAuditLogView(onReturnToHosts: { selection = .all })
            } else {
                VStack(spacing: 0) {
                    libraryHeader
                    Divider()
                    libraryGrid
                }
                .background(AppVisualTheme.contentBackground)
            }
        }
        .tint(AppVisualTheme.accent)
        .onChange(of: hostStore.groups) { _, groups in
            guard case .group(let selectedID) = selection else { return }
            if !groups.contains(where: { $0.id == selectedID }) {
                selection = .all
            }
        }
        .confirmationDialog(
            "移動主機到其他分類？",
            isPresented: Binding(
                get: { pendingHostMove != nil },
                set: { if !$0 { pendingHostMove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移動") { confirmPendingHostMove() }
            Button("取消", role: .cancel) { pendingHostMove = nil }
        } message: {
            if let pendingHostMove {
                Text(
                    "將「\(pendingHostMove.hostName)」從「\(pendingHostMove.sourceGroupName)」移動到「\(pendingHostMove.targetGroupName)」。"
                )
            }
        }
    }

    private var libraryHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                libraryHeading
                Spacer(minLength: 12)
                libraryNavigation
            }
            Divider()
            HStack(spacing: 20) {
                libraryActions
                Spacer(minLength: 12)
                librarySearch
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(AppVisualTheme.raisedSurface)
    }

    private var libraryHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            libraryBreadcrumb
            Text("\(allFilteredHosts.count) 台主機")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var libraryNavigation: some View {
        HStack(spacing: 8) {
            Button("Known Hosts", systemImage: "checkmark.shield") {
                selection = .knownHosts
            }
            Button("Logs", systemImage: "clock.arrow.circlepath") {
                selection = .logs
            }
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private var librarySearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋主機", text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 220)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 8))
    }

    private var libraryActions: some View {
        HStack(spacing: 10) {
            Menu {
                Button("新增主機", systemImage: "plus.rectangle.on.folder") {
                    onAddHost(selectedDefaultGroupID)
                }
                Button(
                    selectedDefaultGroupID == nil ? "新增群組" : "新增子群組",
                    systemImage: "folder.badge.plus"
                ) {
                    onAddGroup(selectedDefaultGroupID)
                }
            } label: {
                Label("新增", systemImage: "plus")
            }
            Button {
                onOpenLocalTerminal()
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .buttonStyle(HostLibraryTerminalButtonStyle())
            Button {
                onOpenSerial()
            } label: {
                Label("Serial", systemImage: "cable.connector")
            }
            .buttonStyle(.bordered)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var libraryBreadcrumb: some View {
        if selectedGroupAncestry.isEmpty {
            Text(pageTitle)
                .font(.title2.weight(.semibold))
        } else {
            HStack(spacing: 7) {
                Button("所有主機") {
                    selection = .all
                }
                .buttonStyle(.link)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .help("回到所有主機")

                ForEach(Array(selectedGroupAncestry.enumerated()), id: \.element.id) { index, group in
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    if index == selectedGroupAncestry.count - 1 {
                        Text(group.name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                    } else {
                        Button(group.name) {
                            selection = .group(group.id)
                        }
                        .buttonStyle(.link)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .help("回到 \(group.name)")
                    }
                }
            }
        }
    }

    private var libraryGrid: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !visibleGroups.isEmpty {
                        cardSectionTitle("分類")
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(visibleGroups) { group in
                                GroupCard(
                                    group: group,
                                    hostCount: hostStore.hostCount(in: group.id),
                                    isSelected: selectedGroupCardID == group.id,
                                    onSelect: {
                                        selectedGroupCardID = group.id
                                        hostStore.selectedHostID = nil
                                    },
                                    onOpen: {
                                        selection = .group(group.id)
                                    }
                                )
                                .contextMenu {
                                    Button("開啟分類") { selection = .group(group.id) }
                                    Button("新增子群組") { onAddGroup(group.id) }
                                    Button("編輯群組") { onRenameGroup(group) }
                                    Button("刪除群組", role: .destructive) { onDeleteGroup(group) }
                                }
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: HostGroupCardFramePreferenceKey.self,
                                            value: [
                                                group.id: proxy.frame(
                                                    in: .named(HostLibraryDragCoordinateSpace.name)
                                                )
                                            ]
                                        )
                                    }
                                }
                                .hostGroupDropHighlight(targetedDropGroupID == group.id)
                            }
                        }
                    }

                    cardSectionTitle("主機")
                    if allFilteredHosts.isEmpty {
                        ContentUnavailableView {
                            Label(searchText.isEmpty ? "這個分類還沒有主機" : "找不到主機", systemImage: "server.rack")
                        } description: {
                            Text(searchText.isEmpty ? "新增一台主機，或從其他分類移入。" : "請嘗試其他搜尋內容。")
                        } actions: {
                            if searchText.isEmpty {
                                Button("新增主機") { onAddHost(selectedDefaultGroupID) }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(allFilteredHosts) { host in
                                HostCard(host: host, isSelected: hostStore.selectedHostID == host.id) {
                                    hostStore.selectedHostID = host.id
                                } onConnect: {
                                    onConnectHost(host)
                                }
                                .contextMenu {
                                    Button("連線", systemImage: "terminal") { onConnectHost(host) }
                                    Button("使用其他帳號連線", systemImage: "person.crop.circle") { onConnectOtherAccount(host) }
                                    Button("開啟 SFTP", systemImage: "folder") { onOpenSFTP(host) }
                                    Divider()
                                    Button("編輯", systemImage: "pencil") { onEditHost(host) }
                                    Button("刪除", systemImage: "trash", role: .destructive) { onDeleteHost(host) }
                                }
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: HostCardFramePreferenceKey.self,
                                            value: [
                                                host.id: proxy.frame(
                                                    in: .named(HostLibraryDragCoordinateSpace.name)
                                                )
                                            ]
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }

            HostLibraryDragMonitor(
                isEnabled: isActive,
                beginDrag: beginHostDrag,
                changeDrag: changeHostDrag,
                endDrag: endHostDrag,
                cancelDrag: resetHostDrag
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let draggedHostID,
               let host = hostStore.profile(id: draggedHostID),
               let hostDragLocation {
                HostLibraryDragGhost(host: host)
                    .position(hostDragLocation)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: HostLibraryDragCoordinateSpace.name)
        .onPreferenceChange(HostGroupCardFramePreferenceKey.self) { groupCardFrames = $0 }
        .onPreferenceChange(HostCardFramePreferenceKey.self) { hostCardFrames = $0 }
        .background(AppVisualTheme.contentBackground)
        .onChange(of: selection) { _, _ in
            selectedGroupCardID = nil
            resetHostDrag()
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 245, maximum: 380), spacing: 14)]
    }

    private func cardSectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func prepareHostMove(hostID: HostProfile.ID, to targetGroupID: HostGroup.ID) {
        guard let host = hostStore.profile(id: hostID) else {
            hostStore.lastError = HostGroupMoveError.missingHost.localizedDescription
            return
        }
        guard host.groupID != targetGroupID else { return }

        guard hostStore.group(id: targetGroupID) != nil else {
            hostStore.lastError = HostGroupMoveError.missingGroup.localizedDescription
            return
        }

        pendingHostMove = HostGroupMoveRequest(
            hostID: host.id,
            hostName: host.displayName,
            sourceGroupName: hostStore.groupName(for: host),
            targetGroupID: targetGroupID,
            targetGroupName: hostStore.groupPath(for: targetGroupID)
        )
    }

    private func beginHostDrag(at point: CGPoint) -> HostProfile.ID? {
        guard HostLibraryDragActivationPolicy.canBegin(
            isHostLibraryVisible: isActive,
            isAllHostsSelection: selection == .all,
            hasPendingMove: pendingHostMove != nil
        ) else { return nil }
        return HostGroupDropHitTesting.hostID(at: point, hostFrames: hostCardFrames)
    }

    private func changeHostDrag(hostID: HostProfile.ID, location: CGPoint) {
        guard selection == .all, hostStore.profile(id: hostID) != nil else {
            resetHostDrag()
            return
        }
        draggedHostID = hostID
        hostDragLocation = location
        targetedDropGroupID = targetGroup(at: location, for: hostID)
    }

    private func endHostDrag(hostID: HostProfile.ID, location: CGPoint) {
        let targetGroupID = targetGroup(at: location, for: hostID)
        resetHostDrag()
        guard let targetGroupID else { return }
        prepareHostMove(hostID: hostID, to: targetGroupID)
    }

    private func targetGroup(at point: CGPoint, for hostID: HostProfile.ID) -> HostGroup.ID? {
        let sourceGroupID = hostStore.profile(id: hostID)?.groupID
        return HostGroupDropHitTesting.groupID(
            at: point,
            groupFrames: groupCardFrames,
            excluding: sourceGroupID
        )
    }

    private func resetHostDrag() {
        draggedHostID = nil
        hostDragLocation = nil
        targetedDropGroupID = nil
    }

    private func confirmPendingHostMove() {
        guard let request = pendingHostMove else { return }
        pendingHostMove = nil
        do {
            try hostStore.moveHost(id: request.hostID, to: request.targetGroupID)
        } catch {
            hostStore.lastError = error.localizedDescription
        }
    }
}

/// Draw both foreground and background explicitly: the native prominent style
/// can lose its rendering when this host window becomes inactive.
private struct HostLibraryTerminalButtonStyle: ButtonStyle {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let emphasized = isEnabled && controlActiveState != .inactive
        return configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(isEnabled
                ? (emphasized ? AppVisualTheme.onAccent : AppVisualTheme.primaryText)
                : AppVisualTheme.secondaryText)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(emphasized ? AppVisualTheme.accent : AppVisualTheme.subtleSurface)
                    .opacity(configuration.isPressed && isEnabled ? 0.78 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(emphasized ? Color.clear : AppVisualTheme.separator, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 5))
    }
}

private struct GroupCard: View {
    let group: HostGroup
    let hostCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(AppVisualTheme.selectedSurface, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.headline).lineLimit(1)
                    Text("\(hostCount) 台主機").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(cardBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .onHover { isHovered = $0 }
        .accessibilityAction(named: "開啟分類", onOpen)
    }
}

private struct HostCard: View {
    let host: HostProfile
    let isSelected: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                HostPlatformBadge(platform: host.detectedPlatform, isSelected: isSelected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.displayName).font(.headline).lineLimit(1)
                    Text(host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(cardBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onConnect))
        .onHover { isHovered = $0 }
        .accessibilityAction(named: "連線", onConnect)
    }
}

private func cardBackground(isSelected: Bool, isHovered: Bool) -> some View {
    RoundedRectangle(cornerRadius: 11)
        .fill(
            isSelected
                ? AppVisualTheme.selectedSurface
                : isHovered
                    ? AppVisualTheme.hoverSurface
                    : AppVisualTheme.raisedSurface
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    isSelected
                        ? AppVisualTheme.accent
                        : isHovered ? AppVisualTheme.accent.opacity(0.48) : AppVisualTheme.inactiveOutline,
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
}

private extension View {
    func hostGroupDropHighlight(_ isTargeted: Bool) -> some View {
        scaleEffect(isTargeted ? 1.008 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .fill(AppVisualTheme.selectedSurface.opacity(isTargeted ? 0.82 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(
                                AppVisualTheme.accent.opacity(isTargeted ? 0.68 : 0),
                                lineWidth: 1.5
                            )
                    }
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if isTargeted {
                    Label("放到此分類", systemImage: "tray.and.arrow.down.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppVisualTheme.raisedSurface, in: .capsule)
                        .overlay {
                            Capsule()
                                .stroke(AppVisualTheme.separator, lineWidth: 1)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

private struct HostLibraryDragGhost: View {
    let host: HostProfile

    var body: some View {
        HStack(spacing: 8) {
            HostPlatformBadge(platform: host.detectedPlatform, size: 26, isSelected: false)
            Text(host.displayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppVisualTheme.raisedSurface, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(AppVisualTheme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}
