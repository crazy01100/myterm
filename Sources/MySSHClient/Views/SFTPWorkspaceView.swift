import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SFTPWorkspaceView: View {
    let onClose: () -> Void
    @StateObject private var localStore = LocalFileBrowserStore()
    @StateObject private var remoteStore = SFTPRemoteBrowserStore()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                LocalSFTPFilePane(store: localStore, remoteStore: remoteStore, onClose: onClose)
                    .frame(width: max(420, geometry.size.width * 0.5))
                Divider()
                RemoteSFTPFilePane(store: remoteStore, localStore: localStore, onClose: onClose)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(AppVisualTheme.contentBackground)
        .alert("本機檔案操作失敗", isPresented: localErrorBinding) {
            Button("好") { localStore.errorMessage = nil }
        } message: {
            Text(localStore.errorMessage ?? "未知錯誤")
        }
        .alert("SFTP 操作失敗", isPresented: remoteErrorBinding) {
            Button("好") { remoteStore.errorMessage = nil }
        } message: {
            Text(remoteStore.errorMessage ?? "未知錯誤")
        }
        .sheet(item: overwriteRequestBinding) { request in
            SFTPOverwriteConfirmationSheet(
                request: request,
                onCancel: remoteStore.cancelOverwrite,
                onOverwrite: remoteStore.confirmOverwrite
            )
        }
    }

    private var localErrorBinding: Binding<Bool> {
        Binding(
            get: { localStore.errorMessage != nil },
            set: { if !$0 { localStore.errorMessage = nil } }
        )
    }

    private var remoteErrorBinding: Binding<Bool> {
        Binding(
            get: { remoteStore.errorMessage != nil },
            set: { if !$0 { remoteStore.errorMessage = nil } }
        )
    }

    private var overwriteRequestBinding: Binding<SFTPOverwriteRequest?> {
        Binding(
            get: { remoteStore.overwriteRequest },
            set: { if $0 == nil { remoteStore.cancelOverwrite() } }
        )
    }
}

private struct LocalSFTPFilePane: View {
    @ObservedObject var store: LocalFileBrowserStore
    @ObservedObject var remoteStore: SFTPRemoteBrowserStore
    let onClose: () -> Void
    @State private var renameEntry: LocalFileEntry?
    @State private var permissionEntry: LocalFileEntry?
    @State private var showingNewFolder = false
    @State private var confirmingDelete = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            localPathBar
            Divider()
            SFTPFileListHeader()
            Divider()
            fileList
        }
        .background(AppVisualTheme.contentBackground)
        .sheet(item: $renameEntry) { entry in
            SFTPTextInputSheet(title: "重新命名", label: "新名稱", initialValue: entry.name) {
                try store.rename(entry, to: $0)
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            SFTPTextInputSheet(title: "新增本機資料夾", label: "資料夾名稱", initialValue: "") {
                try store.createDirectory(named: $0)
            }
        }
        .sheet(item: $permissionEntry) { entry in
            SFTPPermissionSheet(
                name: entry.name,
                path: entry.url.path,
                kind: entry.kind,
                initialPermissions: entry.permissions
            ) {
                try store.setPermissions($0, for: entry)
            }
        }
        .confirmationDialog("移到垃圾桶？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("移到垃圾桶", role: .destructive) {
                do { try store.moveSelectedToTrash() }
                catch { store.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("選取的 \(store.selectedURLs.count) 個項目會移到 macOS 垃圾桶，可以從垃圾桶復原。")
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(AppVisualTheme.selectedSurface, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("本機").font(.headline)
                Text(FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            Menu {
                Button("開啟") { openSelected() }.disabled(store.selectedURLs.count != 1)
                Button("使用其他 App 開啟…") { openSelectedWithApplication() }
                    .disabled(store.selectedEntries.count != 1 || store.selectedEntries.first?.isNavigableDirectory == true)
                Button("複製到遠端目錄", systemImage: "arrow.right") {
                    remoteStore.upload(localURLs: store.selectedEntries.map(\.url))
                }
                .disabled(remoteStore.state != .connected || store.selectedURLs.isEmpty)
                Divider()
                Button("重新命名…") { renameEntry = store.selectedEntries.first }
                    .disabled(store.selectedURLs.count != 1)
                Button("移到垃圾桶…", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(store.selectedURLs.isEmpty)
                Divider()
                Button("重新整理", systemImage: "arrow.clockwise") { store.reload() }
                Button("新增資料夾…", systemImage: "folder.badge.plus") { showingNewFolder = true }
                Button(store.showHiddenFiles ? "隱藏隱藏檔案" : "顯示隱藏檔案",
                       systemImage: store.showHiddenFiles ? "eye.slash" : "eye") {
                    store.showHiddenFiles.toggle()
                }
                Button("編輯權限…", systemImage: "lock") { permissionEntry = store.selectedEntries.first }
                    .disabled(store.selectedURLs.count != 1)
                Button("全選", systemImage: "checkmark.circle") { store.selectAllVisible() }
                Divider()
                Button("關閉 SFTP", systemImage: "xmark", role: .destructive) {
                    remoteStore.disconnect()
                    onClose()
                }
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(AppVisualTheme.raisedSurface)
    }

    private var localPathBar: some View {
        HStack(spacing: 5) {
            Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!store.canGoBack)
            Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!store.canGoForward)
            Divider().frame(height: 18).padding(.horizontal, 3)
            SFTPBreadcrumbTrail(components: localPathComponents) { path in
                store.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(AppVisualTheme.subtleSurface)
    }

    private var localPathComponents: [SFTPBreadcrumbComponent] {
        let names = store.currentURL.standardizedFileURL.path
            .split(separator: "/")
            .map(String.init)
        if names.isEmpty {
            return [SFTPBreadcrumbComponent(title: "/", destination: "/")]
        }
        var result: [SFTPBreadcrumbComponent] = []
        var url = URL(fileURLWithPath: "/", isDirectory: true)
        for name in names {
            url.append(path: name, directoryHint: .isDirectory)
            result.append(SFTPBreadcrumbComponent(
                title: name,
                destination: url.standardizedFileURL.path
            ))
        }
        return result
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.visibleEntries) { entry in
                    localEntryRow(entry)
                    Divider().padding(.leading, 42)
                }
            }
        }
        .onDrop(of: [SFTPDragAndDrop.remotePayloadType], isTargeted: $isDropTargeted) { providers in
            SFTPDragAndDrop.loadRemote(from: providers) { payload in
                _ = remoteStore.download(payloads: [payload], to: store.currentURL) {
                    store.reload()
                }
            }
        }
        .overlay {
            if !store.isLoading && store.visibleEntries.isEmpty {
                ContentUnavailableView("這個資料夾是空的", systemImage: "folder")
            }
        }
        .overlay {
            if isDropTargeted {
                SFTPDropTargetOverlay(title: "下載到目前本機資料夾")
            }
        }
    }

    private func localEntryRow(_ entry: LocalFileEntry) -> some View {
        Button {
            store.toggleSelection(
                entry,
                extending: NSEvent.modifierFlags.contains(.command)
            )
        } label: {
            LocalFileRow(entry: entry, isSelected: store.selectedURLs.contains(entry.url))
                .contentShape(.rect)
        }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                openLocalEntry(entry)
            })
            .contextMenu { localContextMenu(for: entry) }
            .onDrag {
                SFTPDragAndDrop.localProvider(store.dragPayload(for: entry))
            }
    }

    private func openLocalEntry(_ entry: LocalFileEntry) {
        if entry.isNavigableDirectory { store.open(entry) }
        else { NSWorkspace.shared.open(entry.url) }
    }

    private func openSelected() {
        guard let entry = store.selectedEntries.first else { return }
        if entry.isNavigableDirectory { store.open(entry) }
        else { NSWorkspace.shared.open(entry.url) }
    }

    private func openSelectedWithApplication() {
        guard let entry = store.selectedEntries.first, !entry.isNavigableDirectory,
              let applicationURL = SFTPApplicationPicker.chooseApplication() else { return }
        SFTPApplicationPicker.open(entry.url, with: applicationURL)
    }

    @ViewBuilder
    private func localContextMenu(for entry: LocalFileEntry) -> some View {
        let targets = contextEntries(for: entry)
        Button("開啟") {
            guard let target = targets.first else { return }
            if target.isNavigableDirectory {
                store.open(target)
            } else {
                NSWorkspace.shared.open(target.url)
            }
        }
        .disabled(targets.count != 1)
        Button("使用其他 App 開啟…") {
            guard let target = targets.first, !target.isNavigableDirectory,
                  let applicationURL = SFTPApplicationPicker.chooseApplication() else { return }
            SFTPApplicationPicker.open(target.url, with: applicationURL)
        }
        .disabled(targets.count != 1 || targets.first?.isNavigableDirectory == true)
        Button("複製到遠端目錄", systemImage: "arrow.right") {
            remoteStore.upload(localURLs: targets.map(\.url))
        }
        .disabled(remoteStore.state != .connected || targets.isEmpty)
        Divider()
        Button("重新命名…") { renameEntry = targets.first }
            .disabled(targets.count != 1)
        Button("移到垃圾桶…", systemImage: "trash", role: .destructive) {
            selectContextEntries(for: entry)
            confirmingDelete = true
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("重新整理", systemImage: "arrow.clockwise") { store.reload() }
        Button("新增資料夾…", systemImage: "folder.badge.plus") { showingNewFolder = true }
        Button("編輯權限…", systemImage: "lock") { permissionEntry = targets.first }
            .disabled(targets.count != 1)
    }

    private func contextEntries(for entry: LocalFileEntry) -> [LocalFileEntry] {
        store.selectedURLs.contains(entry.url) ? store.selectedEntries : [entry]
    }

    private func selectContextEntries(for entry: LocalFileEntry) {
        if !store.selectedURLs.contains(entry.url) {
            store.selectedURLs = [entry.url]
        }
    }
}

private struct RemoteSFTPFilePane: View {
    @ObservedObject var store: SFTPRemoteBrowserStore
    @ObservedObject var localStore: LocalFileBrowserStore
    let onClose: () -> Void
    @State private var renameEntry: SFTPDirectoryEntry?
    @State private var permissionEntry: SFTPDirectoryEntry?
    @State private var showingNewFolder = false
    @State private var confirmingDelete = false
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            switch store.state {
            case .disconnected, .failed:
                SFTPHostSelector { host, username in store.connect(to: host, username: username) }
            case .connecting:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(store.currentPath.isEmpty ? "正在建立安全的 SFTP 連線…" : "正在讀取遠端目錄…")
                        .font(.headline)
                    if let host = store.connectedHost {
                        Text("\(store.connectedUsername)@\(host.hostname):\(host.port)")
                            .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Button("取消") { store.disconnect() }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                remoteFileBrowser
            }
        }
        .background(AppVisualTheme.contentBackground)
        .sheet(item: $renameEntry) { entry in
            SFTPTextInputSheet(title: "重新命名遠端項目", label: "新名稱", initialValue: entry.name) {
                store.rename(entry, to: $0)
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            SFTPTextInputSheet(title: "新增遠端資料夾", label: "資料夾名稱", initialValue: "") {
                store.createDirectory(named: $0)
            }
        }
        .sheet(item: $permissionEntry) { entry in
            SFTPPermissionSheet(
                name: entry.name,
                path: remoteItemPath(for: entry),
                kind: entry.attributes.kind,
                initialPermissions: entry.attributes.permissions
            ) {
                store.setPermissions($0, for: entry)
            }
        }
        .confirmationDialog("永久刪除遠端項目？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("永久刪除", role: .destructive) { store.deleteSelected() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("選取的 \(store.selectedNames.count) 個遠端項目會直接刪除，無法從垃圾桶復原。資料夾內的內容也會一併刪除。")
        }
    }

    private var remoteFileBrowser: some View {
        VStack(spacing: 0) {
            remoteHeader
            Divider()
            remotePathBar
            Divider()
            SFTPFileListHeader()
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleEntries) { entry in
                        remoteEntryRow(entry)
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .onDrop(
                of: [SFTPDragAndDrop.localPayloadType, .fileURL],
                isTargeted: $isDropTargeted
            ) { providers in
                if SFTPDragAndDrop.loadLocal(from: providers, completion: { payload in
                    _ = store.upload(payloads: [payload], from: localStore)
                }) {
                    return true
                }
                return SFTPDragAndDrop.loadExternalFileURLs(from: providers) { urls in
                    store.upload(localURLs: urls)
                }
            }
            .overlay {
                if store.visibleEntries.isEmpty {
                    ContentUnavailableView("這個遠端資料夾是空的", systemImage: "folder")
                }
            }
            .overlay {
                if isDropTargeted {
                    SFTPDropTargetOverlay(title: "上傳到目前遠端資料夾")
                }
            }
            if !store.transferItems.isEmpty {
                Divider()
                SFTPTransferQueueBar(items: store.transferItems, onClear: store.clearCompletedTransfers)
            }
        }
    }

    private func remoteEntryRow(_ entry: SFTPDirectoryEntry) -> some View {
        Button {
            store.toggleSelection(
                entry,
                extending: NSEvent.modifierFlags.contains(.command)
            )
        } label: {
            RemoteFileRow(entry: entry, isSelected: store.selectedNames.contains(entry.name))
                .contentShape(.rect)
        }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                openRemoteEntry(entry)
            })
            .contextMenu { remoteContextMenu(for: entry) }
            .onDrag {
                SFTPDragAndDrop.remoteProvider(store.dragPayload(for: entry))
            }
    }

    private func openRemoteEntry(_ entry: SFTPDirectoryEntry) {
        if entry.isDirectory { store.open(entry) }
        else { openRemote(entry, withApplication: false) }
    }

    private var remoteHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "network")
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(AppVisualTheme.selectedSurface, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(store.connectedHost?.displayName ?? "SFTP").font(.headline)
                if let host = store.connectedHost {
                    Text("\(store.connectedUsername)@\(host.hostname)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isFileOperationInProgress { ProgressView().controlSize(.small) }
            Menu {
                Button("開啟") {
                    if let entry = store.selectedEntries.first {
                        entry.isDirectory ? store.open(entry) : openRemote(entry, withApplication: false)
                    }
                }
                .disabled(store.selectedNames.count != 1)
                Button("使用其他 App 開啟…") {
                    if let entry = store.selectedEntries.first { openRemote(entry, withApplication: true) }
                }
                .disabled(store.selectedEntries.count != 1 || store.selectedEntries.first?.isDirectory == true)
                Button("複製到本機目錄", systemImage: "arrow.left") {
                    store.download(entries: store.selectedEntries, to: localStore.currentURL) {
                        localStore.reload()
                    }
                }
                .disabled(store.selectedNames.isEmpty)
                Divider()
                Button("重新命名…") { renameEntry = store.selectedEntries.first }
                    .disabled(store.selectedNames.count != 1)
                Button("永久刪除…", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(store.selectedNames.isEmpty)
                Divider()
                Button("重新整理", systemImage: "arrow.clockwise") { store.reload() }
                Button("新增資料夾…", systemImage: "folder.badge.plus") { showingNewFolder = true }
                Button(store.showHiddenFiles ? "隱藏隱藏檔案" : "顯示隱藏檔案",
                       systemImage: store.showHiddenFiles ? "eye.slash" : "eye") {
                    store.showHiddenFiles.toggle()
                }
                Button("編輯權限…", systemImage: "lock") { permissionEntry = store.selectedEntries.first }
                    .disabled(store.selectedNames.count != 1)
                Button("全選", systemImage: "checkmark.circle") { store.selectAllVisible() }
                Divider()
                Button("關閉 SFTP", systemImage: "xmark", role: .destructive) {
                    store.disconnect()
                    onClose()
                }
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(AppVisualTheme.raisedSurface)
    }

    private var remotePathBar: some View {
        HStack(spacing: 4) {
            Button { store.goToParent() } label: { Image(systemName: "chevron.left") }
                .disabled(store.currentPath == "/")
            Divider().frame(height: 18).padding(.horizontal, 3)
            SFTPBreadcrumbTrail(components: remotePathComponents) { path in
                store.goToPathComponent(path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(AppVisualTheme.subtleSurface)
    }

    private var remotePathComponents: [SFTPBreadcrumbComponent] {
        let names = store.currentPath.split(separator: "/").map(String.init)
        var result = [SFTPBreadcrumbComponent(title: "/", destination: "/")]
        var path = ""
        for name in names {
            path += "/\(name)"
            result.append(SFTPBreadcrumbComponent(title: name, destination: path))
        }
        return result
    }

    private func remoteItemPath(for entry: SFTPDirectoryEntry) -> String {
        let basePath = store.currentPath == "/" ? "" : store.currentPath
        return "\(basePath)/\(entry.name)"
    }

    private func openRemote(_ entry: SFTPDirectoryEntry, withApplication: Bool) {
        store.prepareTemporaryCopy(of: entry) { result in
            switch result {
            case .success(let url):
                if withApplication, let appURL = SFTPApplicationPicker.chooseApplication() {
                    SFTPApplicationPicker.open(url, with: appURL)
                } else if !withApplication {
                    NSWorkspace.shared.open(url)
                }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func remoteContextMenu(for entry: SFTPDirectoryEntry) -> some View {
        let targets = contextEntries(for: entry)
        Button("開啟") {
            guard let target = targets.first else { return }
            target.isDirectory ? store.open(target) : openRemote(target, withApplication: false)
        }
        .disabled(targets.count != 1)
        Button("使用其他 App 開啟…") {
            guard let target = targets.first else { return }
            openRemote(target, withApplication: true)
        }
        .disabled(targets.count != 1 || targets.first?.isDirectory == true)
        Button("複製到本機目錄", systemImage: "arrow.left") {
            store.download(entries: targets, to: localStore.currentURL) {
                localStore.reload()
            }
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("重新命名…") { renameEntry = targets.first }
            .disabled(targets.count != 1)
        Button("永久刪除…", systemImage: "trash", role: .destructive) {
            selectContextEntries(for: entry)
            confirmingDelete = true
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("重新整理", systemImage: "arrow.clockwise") { store.reload() }
        Button("新增資料夾…", systemImage: "folder.badge.plus") { showingNewFolder = true }
        Button("編輯權限…", systemImage: "lock") { permissionEntry = targets.first }
            .disabled(targets.count != 1)
    }

    private func contextEntries(for entry: SFTPDirectoryEntry) -> [SFTPDirectoryEntry] {
        store.selectedNames.contains(entry.name) ? store.selectedEntries : [entry]
    }

    private func selectContextEntries(for entry: SFTPDirectoryEntry) {
        if !store.selectedNames.contains(entry.name) {
            store.selectedNames = [entry.name]
        }
    }
}

private struct SFTPHostSelector: View {
    @EnvironmentObject private var hostStore: HostStore
    let onConnect: (HostProfile, String) -> Void
    @State private var currentGroupID: HostGroup.ID?
    @State private var searchText = ""
    @State private var selectedGroupID: HostGroup.ID?
    @State private var selectedHostID: HostProfile.ID?
    @State private var hoveredGroupID: HostGroup.ID?
    @State private var hoveredHostID: HostProfile.ID?
    @State private var usernameHost: HostProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("選擇 SFTP 主機").font(.headline)
                    Text("連按兩下主機即可連線").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(AppVisualTheme.raisedSurface)
            Divider()

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button("全部主機") { navigate(to: nil) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                    ForEach(currentGroupID.map(hostStore.groupAncestry(for:)) ?? []) { group in
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)
                        Button(group.name) { navigate(to: group.id) }
                            .buttonStyle(.plain)
                            .font(.callout.weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextField("搜尋主機", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 7) {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(visibleGroups) { group in
                            Button {
                                selectedGroupID = group.id
                                selectedHostID = nil
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3).foregroundStyle(.tint)
                                        .frame(width: 34, height: 34)
                                        .background(AppVisualTheme.selectedSurface, in: .rect(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name).font(.headline)
                                        Text("\(hostStore.hostCount(in: group.id)) 台主機")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background {
                                    selectorCardBackground(
                                        isSelected: selectedGroupID == group.id,
                                        isHovered: hoveredGroupID == group.id
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovered in
                                hoveredGroupID = isHovered ? group.id : (hoveredGroupID == group.id ? nil : hoveredGroupID)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { navigate(to: group.id) })
                            .accessibilityAction(named: "開啟分類") { navigate(to: group.id) }
                        }
                    }

                    ForEach(visibleHosts) { host in
                        Button {
                            selectedGroupID = nil
                            selectedHostID = host.id
                        } label: {
                            HStack(spacing: 11) {
                                HostPlatformBadge(
                                    platform: host.detectedPlatform,
                                    size: 34,
                                    isSelected: selectedHostID == host.id
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.displayName).font(.headline).lineLimit(1)
                                    Text(host.addressDescription)
                                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background {
                                selectorCardBackground(
                                    isSelected: selectedHostID == host.id,
                                    isHovered: hoveredHostID == host.id
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            hoveredHostID = isHovered ? host.id : (hoveredHostID == host.id ? nil : hoveredHostID)
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { beginConnection(host) })
                        .accessibilityAction(named: "連線") { beginConnection(host) }
                    }
                }
                .padding(12)
            }
            .overlay {
                if visibleGroups.isEmpty && visibleHosts.isEmpty {
                    ContentUnavailableView("沒有可用的主機", systemImage: "server.rack")
                }
            }
        }
        .background(AppVisualTheme.contentBackground)
        .sheet(item: $usernameHost) { host in
            ConnectionUsernameView(host: host, initialUsername: "") { username in
                onConnect(host, username)
            }
        }
    }

    private var visibleGroups: [HostGroup] {
        hostStore.childGroups(of: currentGroupID)
    }

    private var visibleHosts: [HostProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return hostStore.hosts.filter {
                $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.hostname.localizedCaseInsensitiveContains(query) ||
                $0.username.localizedCaseInsensitiveContains(query)
            }
        }
        return hostStore.hosts.filter { $0.groupID == currentGroupID }
    }

    private func beginConnection(_ host: HostProfile) {
        selectedGroupID = nil
        selectedHostID = host.id
        if host.username.isEmpty { usernameHost = host }
        else { onConnect(host, host.username) }
    }

    private func navigate(to groupID: HostGroup.ID?) {
        currentGroupID = groupID
        selectedGroupID = nil
        selectedHostID = nil
        hoveredGroupID = nil
        hoveredHostID = nil
    }

    private func selectorCardBackground(isSelected: Bool, isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(
                isSelected
                    ? AppVisualTheme.selectedSurface
                    : (isHovered ? AppVisualTheme.hoverSurface : AppVisualTheme.raisedSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected
                            ? AppVisualTheme.accent
                            : (isHovered ? AppVisualTheme.accent.opacity(0.45) : AppVisualTheme.inactiveOutline),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
    }
}

private struct SFTPTextInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let label: String
    let onSubmit: (String) throws -> Void
    @State private var value: String
    @State private var errorMessage: String?

    init(
        title: String,
        label: String,
        initialValue: String,
        onSubmit: @escaping (String) throws -> Void
    ) {
        self.title = title
        self.label = label
        self.onSubmit = onSubmit
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            TextField(label, text: $value).textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func submit() {
        do {
            try onSubmit(value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SFTPPermissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let path: String
    let kind: SFTPFileKind
    let onSubmit: (UInt32) throws -> Void
    @State private var mode: SFTPPermissionMode?
    @State private var octalValue: String
    @State private var errorMessage: String?
    @State private var showingAdvanced = false

    init(
        name: String,
        path: String,
        kind: SFTPFileKind,
        initialPermissions: UInt32?,
        onSubmit: @escaping (UInt32) throws -> Void
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.onSubmit = onSubmit
        let initialMode = initialPermissions.map(SFTPPermissionMode.init)
        _mode = State(initialValue: initialMode)
        _octalValue = State(initialValue: initialMode?.octalString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("編輯權限")
                .font(.title2.weight(.semibold))

            targetHeader

            if mode == nil {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("無法取得目前權限")
                            .font(.headline)
                        Text("請重新整理目錄或重新連線後再試，MyTerm 不會用預設值覆蓋未知權限。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 10))
            } else {
                permissionMatrix
                octalEditor
                advancedPermissions
            }

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("套用權限") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == nil || !isOctalValid)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(AppVisualTheme.contentBackground)
    }

    private var targetHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: targetSystemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(AppVisualTheme.selectedSurface, in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            if let mode {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(mode.symbolicString(kind: kind))
                    Text(mode.paddedOctalString)
                }
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("目前權限 \(mode.symbolicString(kind: kind))，八進位 \(mode.paddedOctalString)")
            }
        }
    }

    private var permissionMatrix: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("存取權限")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 12) {
                GridRow {
                    Text("身分")
                    Text("讀取")
                    Text("寫入")
                    Text("執行")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(4)

                ForEach(SFTPPermissionMode.AccessClass.allCases) { accessClass in
                    GridRow {
                        Text(accessClass.title)
                            .frame(width: 150, alignment: .leading)
                        accessToggle(accessClass, .read)
                        accessToggle(accessClass, .write)
                        accessToggle(accessClass, .execute)
                    }
                }
            }

            if kind == .directory {
                Label("資料夾的「執行」代表可以進入或穿越該目錄。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(AppVisualTheme.raisedSurface, in: .rect(cornerRadius: 10))
    }

    private var octalEditor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("八進位權限")
                    .font(.headline)
                Text("可輸入三或四位數字，例如 644、755 或 4755。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("例如 644", text: octalBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 120)
                .accessibilityLabel("八進位權限")
        }
    }

    private var advancedPermissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showingAdvanced.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showingAdvanced ? 90 : 0))
                    Text("進階權限")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("進階權限")
            .accessibilityValue(showingAdvanced ? "已展開" : "已收合")
            .accessibilityHint(showingAdvanced ? "按下以收合" : "按下以展開")

            if showingAdvanced {
                HStack(spacing: 24) {
                    ForEach(SFTPPermissionMode.SpecialRight.allCases) { specialRight in
                        Toggle(specialRight.title, isOn: specialBinding(specialRight))
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func accessToggle(
        _ accessClass: SFTPPermissionMode.AccessClass,
        _ right: SFTPPermissionMode.AccessRight
    ) -> some View {
        Toggle("", isOn: accessBinding(accessClass, right))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("\(accessClass.title)－\(right.title)")
            .accessibilityLabel("\(accessClass.title)\(right.title)權限")
    }

    private func accessBinding(
        _ accessClass: SFTPPermissionMode.AccessClass,
        _ right: SFTPPermissionMode.AccessRight
    ) -> Binding<Bool> {
        Binding(
            get: { mode?.contains(right, for: accessClass) == true },
            set: { enabled in
                guard var updatedMode = mode else { return }
                updatedMode.set(right, for: accessClass, enabled: enabled)
                updateMode(updatedMode)
            }
        )
    }

    private func specialBinding(_ specialRight: SFTPPermissionMode.SpecialRight) -> Binding<Bool> {
        Binding(
            get: { mode?.contains(specialRight) == true },
            set: { enabled in
                guard var updatedMode = mode else { return }
                updatedMode.set(specialRight, enabled: enabled)
                updateMode(updatedMode)
            }
        )
    }

    private var octalBinding: Binding<String> {
        Binding(
            get: { octalValue },
            set: { newValue in
                octalValue = newValue
                if let parsedMode = SFTPPermissionMode(octalString: newValue) {
                    mode = parsedMode
                    errorMessage = nil
                } else {
                    errorMessage = "請輸入 000 到 7777 之間的三或四位八進位權限。"
                }
            }
        )
    }

    private var isOctalValid: Bool {
        SFTPPermissionMode(octalString: octalValue) != nil
    }

    private var targetSystemImage: String {
        switch kind {
        case .directory: "folder.fill"
        case .symbolicLink: "arrowshape.turn.up.right.fill"
        case .regularFile, .other: "doc"
        }
    }

    private func updateMode(_ updatedMode: SFTPPermissionMode) {
        mode = updatedMode
        octalValue = updatedMode.octalString
        errorMessage = nil
    }

    private func submit() {
        guard let submittedMode = SFTPPermissionMode(octalString: octalValue) else {
            errorMessage = "請輸入 000 到 7777 之間的三或四位八進位權限。"
            return
        }
        do {
            try onSubmit(submittedMode.rawValue)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SFTPTransferQueueBar: View {
    let items: [SFTPTransferItem]
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("傳輸", systemImage: "arrow.left.arrow.right")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("清除已完成", action: onClear)
                    .buttonStyle(.borderless).font(.callout)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        HStack(spacing: 7) {
                            Image(systemName: item.direction.symbol)
                                .foregroundStyle(transferColor(item.state))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.state.title).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(.caption)
                            if let progress = item.fractionCompleted,
                               item.state == .transferring {
                                ProgressView(value: progress).frame(width: 58)
                            } else if item.state == .transferring {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 7))
                        .frame(maxWidth: 250)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(9)
        .background(AppVisualTheme.raisedSurface)
    }

    private func transferColor(_ state: SFTPTransferState) -> Color {
        switch state {
        case .completed: .green
        case .failed: .red
        case .waiting: .secondary
        case .transferring: .accentColor
        }
    }
}

private enum SFTPApplicationPicker {
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "選擇用來開啟檔案的 App"
        panel.prompt = "選擇"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(_ fileURL: URL, with applicationURL: URL) {
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private enum SFTPDragAndDrop {
    static let localPayloadType = UTType(
        exportedAs: "tw.local.MySSHClient.sftp.local-drag-payload",
        conformingTo: .data
    )
    static let remotePayloadType = UTType(
        exportedAs: "tw.local.MySSHClient.sftp.remote-drag-payload",
        conformingTo: .data
    )

    static func localProvider(_ payload: SFTPLocalDragPayload) -> NSItemProvider {
        provider(payload, type: localPayloadType)
    }

    static func remoteProvider(_ payload: SFTPRemoteDragPayload) -> NSItemProvider {
        provider(payload, type: remotePayloadType)
    }

    static func loadLocal(
        from providers: [NSItemProvider],
        completion: @escaping (SFTPLocalDragPayload) -> Void
    ) -> Bool {
        load(from: providers, type: localPayloadType, completion: completion)
    }

    static func loadRemote(
        from providers: [NSItemProvider],
        completion: @escaping (SFTPRemoteDragPayload) -> Void
    ) -> Bool {
        load(from: providers, type: remotePayloadType, completion: completion)
    }

    static func loadExternalFileURLs(
        from providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        loadExternalFileURLs(
            from: fileProviders,
            index: 0,
            collected: [],
            completion: completion
        )
        return true
    }

    private static func provider<T: Encodable>(_ payload: T, type: UTType) -> NSItemProvider {
        let itemProvider = NSItemProvider()
        itemProvider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { callback in
            do { callback(try JSONEncoder().encode(payload), nil) }
            catch { callback(nil, error) }
            return nil
        }
        return itemProvider
    }

    private static func load<T: Decodable>(
        from providers: [NSItemProvider],
        type: UTType,
        completion: @escaping (T) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(type.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let payload = try? JSONDecoder().decode(T.self, from: data) else { return }
            DispatchQueue.main.async { completion(payload) }
        }
        return true
    }

    private static func loadExternalFileURLs(
        from providers: [NSItemProvider],
        index: Int,
        collected: [URL],
        completion: @escaping ([URL]) -> Void
    ) {
        guard index < providers.count else {
            DispatchQueue.main.async {
                completion(collected.uniquedByStandardizedPath())
            }
            return
        }

        providers[index].loadItem(
            forTypeIdentifier: UTType.fileURL.identifier,
            options: nil
        ) { item, _ in
            var next = collected
            if let url = externalFileURL(from: item), url.isFileURL {
                next.append(url.standardizedFileURL)
            }
            loadExternalFileURLs(
                from: providers,
                index: index + 1,
                collected: next,
                completion: completion
            )
        }
    }

    private static func externalFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let text = item as? NSString {
            return URL(string: text as String)
        }
        return nil
    }
}

private extension Array where Element == URL {
    func uniquedByStandardizedPath() -> [URL] {
        var paths = Set<String>()
        return filter { paths.insert($0.standardizedFileURL.path).inserted }
    }
}

private struct SFTPBreadcrumbComponent: Identifiable, Hashable {
    let title: String
    let destination: String

    var id: String { destination }
}

private struct SFTPBreadcrumbTrail: View {
    private enum Item: Identifiable {
        case component(SFTPBreadcrumbComponent)
        case omitted([SFTPBreadcrumbComponent])

        var id: String {
            switch self {
            case .component(let component):
                return "component:\(component.destination)"
            case .omitted(let components):
                return "omitted:\(components.map(\.destination).joined(separator: "|"))"
            }
        }
    }

    let components: [SFTPBreadcrumbComponent]
    let onNavigate: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            intrinsicRow(items: components.map(Item.component))
            intrinsicRow(items: compactItems(prefixCount: 3, suffixCount: 2))
            intrinsicRow(items: compactItems(prefixCount: 2, suffixCount: 1))
            flexibleRow(items: compactItems(prefixCount: 1, suffixCount: 1))
        }
    }

    private func compactItems(prefixCount: Int, suffixCount: Int) -> [Item] {
        guard components.count > prefixCount + suffixCount else {
            return components.map(Item.component)
        }
        let prefix = components.prefix(prefixCount).map(Item.component)
        let omittedEnd = components.count - suffixCount
        let omitted = Array(components[prefixCount..<omittedEnd])
        let suffix = components.suffix(suffixCount).map(Item.component)
        return prefix + [.omitted(omitted)] + suffix
    }

    private func intrinsicRow(items: [Item]) -> some View {
        row(items: items)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func flexibleRow(items: [Item]) -> some View {
        row(items: items)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(items: [Item]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                switch item {
                case .component(let component):
                    Button(component.title) { onNavigate(component.destination) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .omitted(let hiddenComponents):
                    Menu {
                        ForEach(hiddenComponents) { component in
                            Button(component.title) { onNavigate(component.destination) }
                        }
                    } label: {
                        Text("…")
                            .font(.callout.weight(.semibold))
                            .accessibilityLabel("顯示省略的路徑")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .clipped()
    }
}

private struct SFTPOverwriteConfirmationSheet: View {
    let request: SFTPOverwriteRequest
    let onCancel: () -> Void
    let onOverwrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("目標位置已有同名項目")
                        .font(.title2.weight(.semibold))
                    Text("這次\(request.direction.title)包含 \(request.names.count) 個同名項目。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(request.names.prefix(6)), id: \.self) { name in
                    Label(name, systemImage: "doc.on.doc")
                        .lineLimit(1)
                }
                if request.names.count > 6 {
                    Text("以及其他 \(request.names.count - 6) 個項目…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 9))

            Text("選擇覆蓋會永久取代目標位置的同名檔案或資料夾；其他沒有衝突的項目也會繼續傳輸。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                Button(action: onOverwrite) {
                    Text("覆蓋")
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.14), in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct SFTPDragPreview: View {
    let name: String
    let count: Int
    let isDirectory: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(isDirectory ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(count > 1 ? "\(count) 個項目" : name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("複製")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppVisualTheme.raisedSurface, in: .rect(cornerRadius: 9))
    }
}

private struct SFTPDropTargetOverlay: View {
    let title: String

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
            .padding(10)
            .overlay {
                Label(title, systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(AppVisualTheme.raisedSurface, in: .capsule)
            }
            .background(AppVisualTheme.selectedSurface.opacity(0.72))
            .allowsHitTesting(false)
    }
}

private struct SFTPFileListHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("名稱").frame(maxWidth: .infinity, alignment: .leading)
            Text("修改日期").frame(width: 132, alignment: .leading)
            Text("大小").frame(width: 78, alignment: .trailing)
            Text("類型").frame(width: 62, alignment: .leading)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(AppVisualTheme.subtleSurface)
    }
}

private struct LocalFileRow: View {
    let entry: LocalFileEntry
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: entry.isSymbolicLink ? "arrowshape.turn.up.right.fill" : (entry.isDirectory ? "folder.fill" : "doc"))
                    .foregroundStyle(entry.isNavigableDirectory ? Color.accentColor : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.body).lineLimit(1)
                    Text(permissionDisplayText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SFTPDisplayFormatter.date(entry.modificationDate))
                .frame(width: 132, alignment: .leading)
            Text(SFTPDisplayFormatter.size(entry.isNavigableDirectory ? nil : entry.size))
                .frame(width: 78, alignment: .trailing)
            Text(entry.kindTitle).frame(width: 62, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(rowBackground)
        .help(permissionHelpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name)，\(entry.kindTitle)，\(permissionAccessibilityText)")
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private var permissionDisplayText: String {
        guard let permissions = entry.permissions else { return "權限未知" }
        return SFTPPermissionMode(permissions).symbolicString(kind: entry.kind)
    }

    private var permissionHelpText: String {
        guard let permissions = entry.permissions else { return "權限未知" }
        let mode = SFTPPermissionMode(permissions)
        return "權限：\(mode.symbolicString(kind: entry.kind))（\(mode.octalString)）"
    }

    private var permissionAccessibilityText: String {
        guard let permissions = entry.permissions else { return "權限未知" }
        let mode = SFTPPermissionMode(permissions)
        return "權限 \(mode.symbolicString(kind: entry.kind))，八進位 \(mode.octalString)"
    }

    private var rowBackground: Color {
        if isSelected { return AppVisualTheme.selectedSurface }
        if isHovered { return AppVisualTheme.hoverSurface }
        return AppVisualTheme.raisedSurface
    }
}

private struct RemoteFileRow: View {
    let entry: SFTPDirectoryEntry
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: entry.isDirectory ? "folder.fill" : (entry.attributes.kind == .symbolicLink ? "arrowshape.turn.up.right.fill" : "doc"))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.body).lineLimit(1)
                    Text(permissionDisplayText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SFTPDisplayFormatter.date(entry.attributes.modificationTime))
                .frame(width: 132, alignment: .leading)
            Text(SFTPDisplayFormatter.size(entry.isDirectory ? nil : entry.attributes.size))
                .frame(width: 78, alignment: .trailing)
            Text(entry.attributes.kind.title).frame(width: 62, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(rowBackground)
        .help(permissionHelpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name)，\(entry.attributes.kind.title)，\(permissionAccessibilityText)")
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private var permissionDisplayText: String {
        guard let permissions = entry.attributes.permissions else { return "權限未知" }
        return SFTPPermissionMode(permissions).symbolicString(kind: entry.attributes.kind)
    }

    private var permissionHelpText: String {
        guard let permissions = entry.attributes.permissions else { return "權限未知" }
        let mode = SFTPPermissionMode(permissions)
        return "權限：\(mode.symbolicString(kind: entry.attributes.kind))（\(mode.octalString)）"
    }

    private var permissionAccessibilityText: String {
        guard let permissions = entry.attributes.permissions else { return "權限未知" }
        let mode = SFTPPermissionMode(permissions)
        return "權限 \(mode.symbolicString(kind: entry.attributes.kind))，八進位 \(mode.octalString)"
    }

    private var rowBackground: Color {
        if isSelected { return AppVisualTheme.selectedSurface }
        if isHovered { return AppVisualTheme.hoverSurface }
        return AppVisualTheme.raisedSurface
    }
}

private enum SFTPDisplayFormatter {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func size(_ size: UInt64?) -> String {
        size.map { byteCount.string(fromByteCount: Int64(clamping: $0)) } ?? "—"
    }

    static func date(_ date: Date?) -> String {
        date.map(dateFormatter.string(from:)) ?? "—"
    }
}
