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
        .background(Color(nsColor: .windowBackgroundColor))
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
            SFTPPermissionSheet(name: entry.name, initialPermissions: entry.permissions ?? 0o644) {
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
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("本機").font(.headline)
                Text(FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            Menu {
                Button("開啟") { openSelected() }.disabled(store.selectedURLs.count != 1)
                Button("使用其他 App 開啟…") { openSelectedWithApplication() }
                    .disabled(store.selectedEntries.count != 1 || store.selectedEntries.first?.isDirectory == true)
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
        .background(.bar)
    }

    private var localPathBar: some View {
        HStack(spacing: 5) {
            Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!store.canGoBack)
            Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!store.canGoForward)
            Divider().frame(height: 18).padding(.horizontal, 3)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(localPathComponents, id: \.url) { component in
                        Button(component.title) { store.navigate(to: component.url) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                        if component.url != localPathComponents.last?.url {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.primary.opacity(0.025))
    }

    private var localPathComponents: [(title: String, url: URL)] {
        let names = store.currentURL.standardizedFileURL.path
            .split(separator: "/")
            .map(String.init)
        var result: [(String, URL)] = [("/", URL(fileURLWithPath: "/", isDirectory: true))]
        var url = URL(fileURLWithPath: "/", isDirectory: true)
        for name in names {
            url.append(path: name, directoryHint: .isDirectory)
            result.append((name, url.standardizedFileURL))
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
        .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
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
        LocalFileRow(entry: entry, isSelected: store.selectedURLs.contains(entry.url))
            .contentShape(.rect)
            .onTapGesture(count: 2) { openLocalEntry(entry) }
            .simultaneousGesture(TapGesture().onEnded {
                store.toggleSelection(entry, extending: NSEvent.modifierFlags.contains(.command))
            })
            .contextMenu { localContextMenu(for: entry) }
            .onDrag {
                SFTPDragAndDrop.localProvider(store.dragPayload(for: entry))
            }
    }

    private func openLocalEntry(_ entry: LocalFileEntry) {
        if entry.isDirectory { store.open(entry) }
        else { NSWorkspace.shared.open(entry.url) }
    }

    private func openSelected() {
        guard let entry = store.selectedEntries.first else { return }
        if entry.isDirectory { store.open(entry) }
        else { NSWorkspace.shared.open(entry.url) }
    }

    private func openSelectedWithApplication() {
        guard let entry = store.selectedEntries.first, !entry.isDirectory,
              let applicationURL = SFTPApplicationPicker.chooseApplication() else { return }
        SFTPApplicationPicker.open(entry.url, with: applicationURL)
    }

    @ViewBuilder
    private func localContextMenu(for entry: LocalFileEntry) -> some View {
        let targets = contextEntries(for: entry)
        Button("開啟") {
            guard let target = targets.first else { return }
            if target.isDirectory {
                store.open(target)
            } else {
                NSWorkspace.shared.open(target.url)
            }
        }
        .disabled(targets.count != 1)
        Button("使用其他 App 開啟…") {
            guard let target = targets.first, !target.isDirectory,
                  let applicationURL = SFTPApplicationPicker.chooseApplication() else { return }
            SFTPApplicationPicker.open(target.url, with: applicationURL)
        }
        .disabled(targets.count != 1 || targets.first?.isDirectory == true)
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
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Button("取消") { store.disconnect() }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                remoteFileBrowser
            }
        }
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
            SFTPPermissionSheet(name: entry.name, initialPermissions: entry.attributes.permissions ?? 0o644) {
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
            .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
                SFTPDragAndDrop.loadLocal(from: providers) { payload in
                    _ = store.upload(payloads: [payload], from: localStore)
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
        RemoteFileRow(entry: entry, isSelected: store.selectedNames.contains(entry.name))
            .contentShape(.rect)
            .onTapGesture(count: 2) { openRemoteEntry(entry) }
            .simultaneousGesture(TapGesture().onEnded {
                store.toggleSelection(entry, extending: NSEvent.modifierFlags.contains(.command))
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
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(store.connectedHost?.displayName ?? "SFTP").font(.headline)
                if let host = store.connectedHost {
                    Text("\(store.connectedUsername)@\(host.hostname)")
                        .font(.caption).foregroundStyle(.secondary)
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
        .background(.bar)
    }

    private var remotePathBar: some View {
        HStack(spacing: 4) {
            Button { store.goToParent() } label: { Image(systemName: "chevron.left") }
                .disabled(store.currentPath == "/")
            Divider().frame(height: 18).padding(.horizontal, 3)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(remotePathComponents, id: \.path) { component in
                        Button(component.title) { store.goToPathComponent(component.path) }
                            .buttonStyle(.plain).font(.caption.weight(.medium))
                        if component.path != remotePathComponents.last?.path {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.primary.opacity(0.025))
    }

    private var remotePathComponents: [(title: String, path: String)] {
        let names = store.currentPath.split(separator: "/").map(String.init)
        var result: [(String, String)] = [("/", "/")]
        var path = ""
        for name in names {
            path += "/\(name)"
            result.append((name, path))
        }
        return result
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
    @State private var selectedHostID: HostProfile.ID?
    @State private var usernameHost: HostProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("選擇 SFTP 主機").font(.headline)
                    Text("連按兩下主機即可連線").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(.bar)
            Divider()

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button("全部主機") { currentGroupID = nil }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                    ForEach(currentGroupID.map(hostStore.groupAncestry(for:)) ?? []) { group in
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Button(group.name) { currentGroupID = group.id }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
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
                            Button { currentGroupID = group.id } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3).foregroundStyle(.tint)
                                        .frame(width: 34, height: 34)
                                        .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name).font(.headline)
                                        Text("\(hostStore.hostCount(in: group.id)) 台主機")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(visibleHosts) { host in
                        Button { selectedHostID = host.id } label: {
                            HStack(spacing: 11) {
                                Image(systemName: host.detectedPlatform == nil ? "terminal" : "server.rack")
                                    .font(.title3)
                                    .foregroundStyle(host.detectedPlatform == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                                    .frame(width: 34, height: 34)
                                    .background(
                                        host.detectedPlatform == nil
                                            ? Color.primary.opacity(0.055)
                                            : Color.accentColor,
                                        in: .rect(cornerRadius: 8)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.displayName).font(.headline).lineLimit(1)
                                    Text(host.addressDescription)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background {
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(selectedHostID == host.id ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9)
                                            .stroke(selectedHostID == host.id ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selectedHostID == host.id ? 1.5 : 1)
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { beginConnection(host) })
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
        selectedHostID = host.id
        if host.username.isEmpty { usernameHost = host }
        else { onConnect(host, host.username) }
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
    let onSubmit: (UInt32) throws -> Void
    @State private var value: String
    @State private var errorMessage: String?

    init(name: String, initialPermissions: UInt32, onSubmit: @escaping (UInt32) throws -> Void) {
        self.name = name
        self.onSubmit = onSubmit
        _value = State(initialValue: String(initialPermissions & 0o7777, radix: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("編輯權限").font(.title2.weight(.semibold))
            Text(name).font(.headline).lineLimit(1)
            TextField("例如 644 或 755", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("請輸入三或四位八進位權限；例如檔案常用 644，資料夾常用 755。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("套用") { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...4).contains(trimmed.count),
              trimmed.allSatisfy({ ("0"..."7").contains(String($0)) }),
              let permissions = UInt32(trimmed, radix: 8), permissions <= 0o7777 else {
            errorMessage = "請輸入 000 到 7777 之間的八進位權限。"
            return
        }
        do {
            try onSubmit(permissions)
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
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("清除已完成", action: onClear)
                    .buttonStyle(.borderless).font(.caption)
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
                            .font(.caption2)
                            if let progress = item.fractionCompleted,
                               item.state == .transferring {
                                ProgressView(value: progress).frame(width: 58)
                            } else if item.state == .transferring {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.055), in: .rect(cornerRadius: 7))
                        .frame(maxWidth: 250)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(9)
        .background(.bar)
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
    static func localProvider(_ payload: SFTPLocalDragPayload) -> NSItemProvider {
        provider(payload, type: .data)
    }

    static func remoteProvider(_ payload: SFTPRemoteDragPayload) -> NSItemProvider {
        provider(payload, type: .data)
    }

    static func loadLocal(
        from providers: [NSItemProvider],
        completion: @escaping (SFTPLocalDragPayload) -> Void
    ) -> Bool {
        load(from: providers, type: .data, completion: completion)
    }

    static func loadRemote(
        from providers: [NSItemProvider],
        completion: @escaping (SFTPRemoteDragPayload) -> Void
    ) -> Bool {
        load(from: providers, type: .data, completion: completion)
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
            .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 9))

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
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("複製")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .rect(cornerRadius: 9))
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
                    .background(.regularMaterial, in: .capsule)
            }
            .background(Color.accentColor.opacity(0.06))
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
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.035))
    }
}

private struct LocalFileRow: View {
    let entry: LocalFileEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: entry.isDirectory ? "folder.fill" : (entry.isSymbolicLink ? "arrowshape.turn.up.right.fill" : "doc"))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 20)
                Text(entry.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SFTPDisplayFormatter.date(entry.modificationDate))
                .frame(width: 132, alignment: .leading)
            Text(SFTPDisplayFormatter.size(entry.isDirectory ? nil : entry.size))
                .frame(width: 78, alignment: .trailing)
            Text(entry.kindTitle).frame(width: 62, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
    }
}

private struct RemoteFileRow: View {
    let entry: SFTPDirectoryEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: entry.isDirectory ? "folder.fill" : (entry.attributes.kind == .symbolicLink ? "arrowshape.turn.up.right.fill" : "doc"))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 20)
                Text(entry.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SFTPDisplayFormatter.date(entry.attributes.modificationTime))
                .frame(width: 132, alignment: .leading)
            Text(SFTPDisplayFormatter.size(entry.isDirectory ? nil : entry.attributes.size))
                .frame(width: 78, alignment: .trailing)
            Text(entry.attributes.kind.title).frame(width: 62, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
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
