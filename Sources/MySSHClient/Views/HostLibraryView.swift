import SwiftUI

enum HostLibrarySelection: Hashable {
    case all
    case group(UUID)
    case ungrouped
    case knownHosts
}

private struct HostGroupNode: Identifiable {
    let group: HostGroup
    let children: [HostGroupNode]?

    var id: HostGroup.ID { group.id }
}

struct HostLibraryView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var knownHostsStore: KnownHostsStore
    @State private var selection: HostLibrarySelection = .all
    @State private var searchText = ""

    let onAddHost: (UUID?) -> Void
    let onAddGroup: (UUID?) -> Void
    let onEditHost: (HostProfile) -> Void
    let onConnectHost: (HostProfile) -> Void
    let onConnectOtherAccount: (HostProfile) -> Void
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
        case .knownHosts: scopedHosts = []
        }
        guard !searchText.isEmpty else { return scopedHosts }
        return scopedHosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText) ||
            hostStore.groupName(for: $0).localizedCaseInsensitiveContains(searchText)
        }
    }

    private var visibleGroups: [HostGroup] {
        let baseGroups: [HostGroup]
        switch selection {
        case .all: baseGroups = hostStore.childGroups(of: nil)
        case .group(let id): baseGroups = hostStore.childGroups(of: id)
        case .ungrouped, .knownHosts: baseGroups = []
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

    private var groupTree: [HostGroupNode] {
        func nodes(parentID: HostGroup.ID?) -> [HostGroupNode] {
            hostStore.childGroups(of: parentID).map { group in
                let descendants = nodes(parentID: group.id)
                return HostGroupNode(group: group, children: descendants.isEmpty ? nil : descendants)
            }
        }
        return nodes(parentID: nil)
    }

    private var pageTitle: String {
        switch selection {
        case .all: "所有主機"
        case .group(let id): hostStore.groupPath(for: id)
        case .ungrouped: "未分類"
        case .knownHosts: "Known Hosts"
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
        NavigationSplitView {
            List(selection: $selection) {
                Section("主機庫") {
                    sidebarRow(title: "所有主機", systemImage: "square.grid.2x2", count: hostStore.hosts.count)
                        .tag(HostLibrarySelection.all)
                }
                Section("分類") {
                    OutlineGroup(groupTree, children: \.children) { node in
                        sidebarRow(
                            title: node.group.name,
                            systemImage: "folder",
                            count: hostStore.hostCount(in: node.id)
                        )
                        .tag(HostLibrarySelection.group(node.id))
                        .contextMenu {
                            Button("新增子群組") { onAddGroup(node.id) }
                            Button("編輯群組") { onRenameGroup(node.group) }
                            Button("刪除群組", role: .destructive) { onDeleteGroup(node.group) }
                        }
                    }
                    sidebarRow(
                        title: "未分類",
                        systemImage: "tray",
                        count: hostStore.hosts.filter { $0.groupID == nil }.count
                    )
                    .tag(HostLibrarySelection.ungrouped)
                }
                Section("其他") {
                    sidebarRow(
                        title: "Known Hosts",
                        systemImage: "checkmark.shield",
                        count: knownHostsStore.records.count
                    )
                    .tag(HostLibrarySelection.knownHosts)
                }
            }
            .navigationTitle("分類")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if selection == .knownHosts {
                KnownHostsView()
            } else {
                VStack(spacing: 0) {
                    libraryHeader
                    Divider()
                    libraryGrid
                }
            }
        }
        .onChange(of: hostStore.groups) { _, groups in
            guard case .group(let selectedID) = selection else { return }
            if !groups.contains(where: { $0.id == selectedID }) {
                selection = .all
            }
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                libraryBreadcrumb
                Text("\(allFilteredHosts.count) 台主機")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋主機", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 220)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.055), in: .rect(cornerRadius: 8))

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
            .buttonStyle(.borderedProminent)
            Button {
                onOpenSerial()
            } label: {
                Label("Serial", systemImage: "cable.connector")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var libraryBreadcrumb: some View {
        if selectedGroupAncestry.isEmpty {
            Text(pageTitle)
                .font(.title2.weight(.semibold))
        } else {
            HStack(spacing: 7) {
                ForEach(Array(selectedGroupAncestry.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !visibleGroups.isEmpty {
                    cardSectionTitle("分類")
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(visibleGroups) { group in
                            GroupCard(
                                group: group,
                                hostCount: hostStore.hostCount(in: group.id)
                            ) {
                                selection = .group(group.id)
                            }
                            .contextMenu {
                                Button("開啟分類") { selection = .group(group.id) }
                                Button("新增子群組") { onAddGroup(group.id) }
                                Button("編輯群組") { onRenameGroup(group) }
                                Button("刪除群組", role: .destructive) { onDeleteGroup(group) }
                            }
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
                                Button("連線") { onConnectHost(host) }
                                Button("使用其他帳號連線") { onConnectOtherAccount(host) }
                                Divider()
                                Button("編輯") { onEditHost(host) }
                                Button("刪除", role: .destructive) { onDeleteHost(host) }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 245, maximum: 380), spacing: 14)]
    }

    private func sidebarRow(title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cardSectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }
}

private struct GroupCard: View {
    let group: HostGroup
    let hostCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.headline).lineLimit(1)
                    Text("\(hostCount) 台主機").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }
}

private struct HostCard: View {
    let host: HostProfile
    let isSelected: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                PlatformBadge(platform: host.detectedPlatform, isSelected: isSelected)
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
            .background {
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? Color.accentColor.opacity(0.11) : Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: isSelected ? 2 : 1)
                    }
            }
        }
        .buttonStyle(HostCardButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded(onConnect))
    }
}

private struct PlatformBadge: View {
    let platform: HostPlatform?
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(badgeColor)
            if let platform {
                Image(systemName: symbolName(for: platform))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "terminal")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .frame(width: 42, height: 42)
        .help(platform?.title ?? "尚未辨識平台")
    }

    private var badgeColor: Color {
        guard let platform else { return Color.primary.opacity(0.055) }
        switch platform {
        case .ubuntu: return Color(red: 0.91, green: 0.25, blue: 0.10)
        case .debian: return Color(red: 0.84, green: 0.00, blue: 0.29)
        case .almaLinux, .rockyLinux: return Color(red: 0.08, green: 0.43, blue: 0.55)
        case .centOS, .redHat, .fedora: return Color(red: 0.08, green: 0.29, blue: 0.52)
        case .amazonLinux: return Color(red: 0.95, green: 0.56, blue: 0.08)
        case .alpine, .openSUSE, .archLinux: return Color(red: 0.05, green: 0.52, blue: 0.68)
        case .macOS: return Color(red: 0.34, green: 0.36, blue: 0.40)
        case .freeBSD: return Color(red: 0.78, green: 0.08, blue: 0.08)
        case .cisco: return Color(red: 0.02, green: 0.68, blue: 0.82)
        case .juniper: return Color(red: 0.12, green: 0.48, blue: 0.26)
        case .arista: return Color(red: 0.12, green: 0.36, blue: 0.66)
        case .openWrt: return Color(red: 0.16, green: 0.43, blue: 0.70)
        }
    }

    private func symbolName(for platform: HostPlatform) -> String {
        switch platform {
        case .ubuntu, .debian, .almaLinux, .rockyLinux, .centOS, .redHat, .fedora,
             .amazonLinux, .alpine, .openSUSE, .archLinux, .freeBSD:
            "server.rack"
        case .macOS: "apple.logo"
        case .cisco, .juniper, .arista, .openWrt: "network"
        }
    }
}

private struct HostCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 11)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
}
