import Foundation

@MainActor
final class LocalFileBrowserStore: ObservableObject {
    @Published private(set) var currentURL: URL {
        didSet { if currentURL != oldValue { searchQuery = "" } }
    }
    @Published private(set) var entries: [LocalFileEntry] = [] { didSet { rebuildSortedEntries() } }
    @Published private(set) var visibleEntries: [LocalFileEntry] = []
    private var sortedEntries: [LocalFileEntry] = []
    @Published private(set) var isLoading = false
    @Published var showHiddenFiles = false { didSet { rebuildVisibleEntries() } }
    @Published var searchQuery = "" { didSet { rebuildVisibleEntries() } }
    @Published var sorting: SFTPListSort {
        didSet { sorting.save(to: sortPreferences, pane: "local"); rebuildSortedEntries() }
    }
    private let sortPreferences: UserDefaults?
    @Published var selectedURLs: Set<URL> = []
    @Published var errorMessage: String?

    @Published private(set) var hasLoadedDirectory = false
    private var backHistory: [URL] = []
    private var forwardHistory: [URL] = []
    private var loadGeneration = UUID()

    init(fileManager: FileManager = .default, sortPreferences: UserDefaults? = SFTPListSort.defaultPreferences) {
        self.sortPreferences = sortPreferences
        sorting = .load(from: sortPreferences, pane: "local")
        currentURL = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        reload()
    }

    private func rebuildSortedEntries() {
        sortedEntries = entries.map { ($0, SFTPListItem($0)) }
            .sorted { sorting.precedes($0.1, $1.1) }.map { $0.0 }
        rebuildVisibleEntries()
    }

    private func rebuildVisibleEntries() {
        visibleEntries = sortedEntries.filter {
            (showHiddenFiles || !$0.isHidden) && SFTPFilenameSearch.matches($0.name, query: searchQuery)
        }
        selectedURLs.formIntersection(Set(visibleEntries.map(\.url)))
    }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    func open(_ entry: LocalFileEntry) {
        guard let directoryURL = entry.navigableDirectoryURL else { return }
        navigate(to: directoryURL)
    }

    func navigate(to url: URL) {
        let target = url.standardizedFileURL
        guard target != currentURL else { return }
        loadDirectory(target, navigation: .new)
    }

    func goBack() {
        guard let target = backHistory.last else { return }
        loadDirectory(target, navigation: .back)
    }

    func goForward() {
        guard let target = forwardHistory.last else { return }
        loadDirectory(target, navigation: .forward)
    }

    func reload() { loadDirectory(currentURL, navigation: .refresh) }

    private enum Navigation { case new, back, forward, refresh }
    private func loadDirectory(_ url: URL, navigation: Navigation) {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.loadEntries(at: url)
                }.value
                guard loadGeneration == generation else { return }
                let oldURL = currentURL
                switch navigation {
                case .new: backHistory.append(oldURL); forwardHistory.removeAll()
                case .back: _ = backHistory.popLast(); forwardHistory.append(oldURL)
                case .forward: _ = forwardHistory.popLast(); backHistory.append(oldURL)
                case .refresh: break
                }
                if oldURL != url { selectedURLs.removeAll() }
                currentURL = url
                entries = result
                selectedURLs = selectedURLs.intersection(Set(visibleEntries.map(\.url)))
                hasLoadedDirectory = true
                isLoading = false
            } catch {
                guard loadGeneration == generation else { return }
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleSelection(_ entry: LocalFileEntry, extending: Bool) {
        if extending {
            if !selectedURLs.insert(entry.url).inserted { selectedURLs.remove(entry.url) }
        } else {
            selectedURLs = [entry.url]
        }
    }

    func selectAllVisible() {
        selectedURLs = Set(visibleEntries.map(\.url))
    }

    var selectedEntries: [LocalFileEntry] {
        visibleEntries.filter { selectedURLs.contains($0.url) }
    }

    func dragPayload(for entry: LocalFileEntry) -> SFTPLocalDragPayload {
        let draggedEntries = selectedURLs.contains(entry.url) ? selectedEntries : [entry]
        return SFTPLocalDragPayload(
            paths: draggedEntries.map { $0.url.standardizedFileURL.path }
        )
    }

    func entries(for payloads: [SFTPLocalDragPayload]) -> [LocalFileEntry] {
        let requestedPaths = Set(payloads.flatMap(\.paths))
        return visibleEntries.filter { requestedPaths.contains($0.url.standardizedFileURL.path) }
    }

    func createDirectory(named input: String) throws {
        let name = try Self.validatedName(input)
        let destination = currentURL.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SFTPFileOperationError.destinationExists(name)
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        reload()
    }

    func rename(_ entry: LocalFileEntry, to input: String) throws {
        let name = try Self.validatedName(input)
        let destination = entry.url.deletingLastPathComponent().appending(path: name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SFTPFileOperationError.destinationExists(name)
        }
        try FileManager.default.moveItem(at: entry.url, to: destination)
        selectedURLs = [destination]
        reload()
    }

    func moveSelectedToTrash() throws {
        for entry in selectedEntries {
            _ = try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        }
        selectedURLs.removeAll()
        reload()
    }

    func setPermissions(_ permissions: UInt32, for entry: LocalFileEntry) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: entry.url.path
        )
        reload()
    }

    nonisolated private static func loadEntries(at url: URL) throws -> [LocalFileEntry] {
        return try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            .map { try LocalFileEntry.inspect($0) }
    }

    nonisolated private static func validatedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SFTPFileOperationError.unsafeName(name)
        }
        return name
    }
}

@MainActor
final class SFTPRemoteBrowserStore: ObservableObject, SFTPHostOpeningConnection, SFTPEditConnection {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var connectedHost: HostProfile?
    @Published private(set) var connectedUsername = ""
    @Published private(set) var negotiatedProtection = SSHNegotiatedProtection(status: .closed)
    private var protectionTask: Task<Void, Never>?
    @Published private(set) var homePath = ""
    @Published private(set) var currentPath = "" {
        didSet { if currentPath != oldValue { searchQuery = "" } }
    }
    @Published private(set) var entries: [SFTPDirectoryEntry] = [] { didSet { rebuildSortedEntries() } }
    @Published private(set) var visibleEntries: [SFTPDirectoryEntry] = []
    private var sortedEntries: [SFTPDirectoryEntry] = []
    @Published var showHiddenFiles = false { didSet { rebuildVisibleEntries() } }
    @Published var searchQuery = "" { didSet { rebuildVisibleEntries() } }
    @Published var sorting: SFTPListSort {
        didSet { sorting.save(to: sortPreferences, pane: "remote"); rebuildSortedEntries() }
    }
    private let sortPreferences: UserDefaults?
    @Published var selectedNames: Set<String> = []
    @Published var errorMessage: String?
    @Published private(set) var transferItems: [SFTPTransferItem] = []
    @Published private(set) var isFileOperationInProgress = false
    @Published private(set) var overwriteRequest: SFTPOverwriteRequest?

    private var client: SFTPClient?
    private var directoryRequest = UUID()
    private var connectionCancellation: SFTPCancellation?
    private var generation = UUID()
    private var pendingOverwriteOperation: PendingOverwriteOperation?
    let editStore: SFTPExternalEditStore
    private let editingTrust: (SFTPConnectionTarget) throws -> String
    private var editingInventoryValid = true
    private var latestEditingInventory: [HostProfile]?
    struct EndingStatus {
        var fileName = ""
        var issues: [SFTPExternalEditStore.EndIssue] = []
        var checking = true
    }
    @Published private(set) var endingStatus: EndingStatus?
    private var endingContext: SFTPExternalEditStore.Ending?
    private var endingCancellation: SFTPTransferCancellation?
    private var afterEnding: (() -> Void)?
    var canRequestSwitchWhileBusy: Bool { endingStatus == nil }


    init(editStore: SFTPExternalEditStore? = nil, editingTrust: (() throws -> String)? = nil,
         sortPreferences: UserDefaults? = SFTPListSort.defaultPreferences) {
        self.sortPreferences = sortPreferences
        sorting = .load(from: sortPreferences, pane: "remote")
#if MYTERM_SELF_TESTS
        self.editStore = editStore ?? SFTPExternalEditStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("MyTerm-unused-edit-tests-\(UUID())"))
#else
        self.editStore = editStore ?? .shared
#endif
        self.editingTrust = { target in
            if let editingTrust { return try editingTrust() }
            return try SFTPExternalEditStore.trustDigest(target: target)
        }
    }

    var editingTarget: SFTPConnectionTarget? {
        guard editingInventoryValid, client != nil, state == .connected || state == .connecting else { return nil }
        return connectedHost.map { SFTPConnectionTarget(host: $0, username: connectedUsername) }
    }
    var editingGeneration: UUID { generation }

    func validateEditingInventory(_ hosts: [HostProfile]) {
        latestEditingInventory = hosts
        guard let connectedHost else { return }
        let original = SFTPConnectionTarget(host: connectedHost, username: connectedUsername)
        let valid = hosts.first(where: { $0.id == connectedHost.id }).map {
            SFTPConnectionTarget(host: $0, username: connectedUsername) == original
        } ?? false
        guard !valid else { return }
        editingInventoryValid = false
        endingCancellation?.cancel()
        endingContext = nil; endingCancellation = nil; endingStatus = nil; afterEnding = nil
        editStore.pause(connection: self)
        for id in Array(editTransferIDs.keys) { cancelTransfer(id) }
    }

    private struct FilePreparation {
        let id: UUID
        let target: SFTPConnectionTarget
        let entry: SFTPDirectoryEntry
        let remoteDirectory: String
        let hostName: String
        let trust: String?
        let localURL: URL?
        let editCompletion: ((Result<SFTPEditWork, Error>) -> Void)?
        let previewCompletion: ((Result<URL, Error>) -> Void)?
        let path: String
    }

    private struct TransferWork {
        enum Operation {
            case upload(URL, String, Bool)
            case download(SFTPDirectoryEntry, String, URL, Bool)
            case edit(UUID, SFTPEditSnapshot, String, SFTPEditRevision)
            case editCheck(UUID, String)
            case prepare(FilePreparation)

            var editID: UUID? {
                switch self {
                case .edit(let id, _, _, _), .editCheck(let id, _): id
                default: nil
                }
            }
        }
        let id: UUID
        let generation: UUID
        let operation: Operation
        let completion: () -> Void
    }
    private var pendingTransfers: [TransferWork] = []
    private var activeTransferID: UUID?
    private var transferCancellation: SFTPTransferCancellation?
    private var editTransferIDs: [UUID: UUID] = [:]
    @Published private(set) var preparationRevealToken = UUID()

    var hasActiveTransfers: Bool { transferItems.contains { !$0.state.isFinished } }
    var canForceStopTransfers: Bool { state != .disconnected && hasActiveTransfers }

    private enum PendingOverwriteOperation {
        case upload(
            urls: [URL],
            remoteDirectory: String,
            sessionID: UUID
        )
        case download(
            entries: [SFTPDirectoryEntry],
            remoteDirectory: String,
            localDirectory: URL,
            sessionID: UUID,
            completion: () -> Void
        )
    }

#if MYTERM_SELF_TESTS
    func installTestConnection(_ connection: SFTPClient, host: HostProfile) {
        disconnect()
        editingInventoryValid = true
        client = connection
        connectedHost = host
        connectedUsername = host.username
        currentPath = "/"
        homePath = "/"
        state = .connected
    }
#endif

    private func rebuildSortedEntries() {
        sortedEntries = entries.map { ($0, SFTPListItem($0)) }
            .sorted { sorting.precedes($0.1, $1.1) }.map { $0.0 }
        rebuildVisibleEntries()
    }

    private func rebuildVisibleEntries() {
        visibleEntries = sortedEntries.filter {
            (showHiddenFiles || !$0.isHidden) && SFTPFilenameSearch.matches($0.name, query: searchQuery)
        }
        selectedNames.formIntersection(Set(visibleEntries.map(\.name)))
    }

    var openingSnapshot: SFTPConnectionSnapshot {
        let active = state == .connected || state == .connecting
        let target = active ? connectedHost.map { SFTPConnectionTarget(host: $0, username: connectedUsername) } : nil
        let transfersPending = hasActiveTransfers
        return SFTPConnectionSnapshot(target: target, generation: generation,
            isBusy: endingStatus != nil || transfersPending || isFileOperationInProgress || overwriteRequest != nil || pendingOverwriteOperation != nil,
            description: connectedHost.map { "\($0.displayName)（\(connectedUsername)@\($0.hostname):\($0.port)）" } ?? "SFTP")
    }

    func connect(to host: HostProfile, username: String) {
        guard endingStatus == nil else { return }
        disconnect()
        editingInventoryValid = true
        let generation = UUID()
        self.generation = generation
        let cancellation = SFTPCancellation()
        connectionCancellation = cancellation
        state = .connecting
        negotiatedProtection = SSHNegotiatedProtection()
        connectedHost = host
        connectedUsername = username
        errorMessage = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let client = try SFTPClient.connect(to: host, username: username, cancellation: cancellation)
                    do {
                        let path = try client.realPath(".")
                        let entries = try client.listDirectory(path)
                        client.completeInitialization()
                        return (client, path, entries)
                    } catch {
                        client.close()
                        throw error
                    }
                }.value
                guard self.generation == generation else {
                    result.0.close()
                    return
                }
                client = result.0
                homePath = result.1
                currentPath = result.1
                entries = result.2
                selectedNames.removeAll()
                state = .connected
                protectionTask?.cancel()
                protectionTask = Task { [weak self, weak currentClient = result.0] in
                    while !Task.isCancelled {
                        if let self, let currentClient {
                            guard self.generation == generation else { return }
                            let protection = currentClient.negotiatedProtection
                            if self.negotiatedProtection != protection { self.negotiatedProtection = protection }
                        } else { return }
                        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    }
                }
                startNextTransfer()
            } catch {
                guard self.generation == generation else { return }
                client = nil
                entries = []
                selectedNames.removeAll()
                state = .failed
                negotiatedProtection = SSHNegotiatedProtection(status: .closed)
                errorMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    func open(_ entry: SFTPDirectoryEntry) {
        guard entry.isDirectory else { return }
        do {
            let name = try Self.validatedName(entry.name)
            load(path: Self.appending(name, to: currentPath))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goToParent() {
        guard endingStatus == nil, state == .connected, currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        load(path: parent.isEmpty ? "/" : parent)
    }

    var canUseDirectoryBookmarks: Bool {
        state == .connected && editingInventoryValid && endingStatus == nil &&
        !isFileOperationInProgress && !hasActiveTransfers && overwriteRequest == nil && pendingOverwriteOperation == nil
    }

    func navigateToBookmark(path: String, hostID: UUID, hostname: String, port: Int, username: String) {
        guard canUseDirectoryBookmarks, let host = connectedHost,
              host.id == hostID, host.hostname == hostname, host.port == port, connectedUsername == username,
              path.hasPrefix("/"), path.utf8.count <= 16 * 1024,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            errorMessage = "目前連線或工作狀態已變更，請稍後重新開啟書籤。"
            return
        }
        guard path != currentPath else { return }
        load(path: path)
    }

    func goToPathComponent(_ path: String) {
        guard endingStatus == nil, state == .connected else { return }
        load(path: path)
    }

    func reload() {
        guard endingStatus == nil, state == .connected else { return }
        load(path: currentPath)
    }

    /// Only explicit UI close/confirmed host switch invokes cache cleanup.
    /// Internal reset, errors and force disconnect continue to retain drafts.
    func requestEnd(completion: @escaping () -> Void = {}) {
        guard endingStatus == nil else { return }
        let end = editStore.beginEnding(connection: self)
        let cancellation = SFTPTransferCancellation()
        endingContext = end; endingCancellation = cancellation; afterEnding = completion
        endingStatus = EndingStatus()
        Task {
            var issues = await editStore.inspectEnding(end, connection: self, cancellation: cancellation) { [weak self] name in
                self?.endingStatus?.fileName = name
            }
            guard endingContext?.id == end.id, generation == end.generation else { return }
            if hasActiveTransfers || isFileOperationInProgress || overwriteRequest != nil || state == .connecting {
                issues.append(.init(id: UUID(), name: "SFTP 工作", reason: "仍有傳輸、目錄讀取或檔案操作未完成"))
            }
            if !issues.isEmpty {
                endingStatus = EndingStatus(issues: issues, checking: false)
            } else {
                await finishEnding(end, preserve: false, excluding: [], cancellation: cancellation)
            }
        }
    }

    func requestSwitch(to host: HostProfile, username: String) {
        let target = SFTPConnectionTarget(host: host, username: username)
        requestEnd { [weak self] in
            guard let self else { return }
            if let inventory = latestEditingInventory,
               !inventory.contains(where: { SFTPConnectionTarget(host: $0, username: username) == target }) {
                errorMessage = "主機連線設定已變更，請重新選擇。"; return
            }
            connect(to: host, username: username)
        }
    }

    func cancelEnding() {
        endingCancellation?.cancel()
        if let end = endingContext { editStore.cancelEnding(end, connection: self) }
        endingContext = nil; endingCancellation = nil; endingStatus = nil; afterEnding = nil
        startNextTransfer()
    }

    func preserveAndEnd() {
        guard let end = endingContext, let cancellation = endingCancellation, endingStatus?.checking == false else { return }
        let excluded = Set(endingStatus?.issues.map(\.id) ?? [])
        endingStatus?.checking = true
        Task { await finishEnding(end, preserve: true, excluding: excluded, cancellation: cancellation) }
    }

    private func finishEnding(_ end: SFTPExternalEditStore.Ending, preserve: Bool, excluding: Set<UUID>,
                              cancellation: SFTPTransferCancellation) async {
        let issues = await editStore.cleanEnding(end, connection: self, excluding: excluding, cancellation: cancellation) { [weak self] name in
            self?.endingStatus?.fileName = name
        }
        guard endingContext?.id == end.id, generation == end.generation else { return }
        if !issues.isEmpty && !preserve {
            endingStatus = EndingStatus(issues: issues, checking: false); return
        }
        guard editStore.preserveEnding(end, connection: self) else {
            endingStatus = EndingStatus(issues: [.init(id: UUID(), name: "編輯工作", reason: "無法保存恢復紀錄，請檢查磁碟空間與權限後再試；現有檔案未刪除")], checking: false)
            return
        }
        let completion = afterEnding
        // pause in disconnect retires the closing runtimes without restarting.
        endingContext = nil; endingCancellation = nil; endingStatus = nil; afterEnding = nil
        disconnect()
        completion?()
        if !issues.isEmpty { editStore.errorMessage = "部分快取清理未完成，尚存檔案與工作紀錄已保留，可在編輯工作中重試。" }
    }

    func disconnect() {
        protectionTask?.cancel()
        protectionTask = nil
        negotiatedProtection = SSHNegotiatedProtection(status: .closed)
        endingCancellation?.cancel()
        endingContext = nil; endingCancellation = nil; endingStatus = nil; afterEnding = nil
        editStore.pause(connection: self)
        generation = UUID()
        connectionCancellation?.cancel()
        connectionCancellation = nil
        client?.close()
        client = nil
        cancelAllTransfers()
        pendingTransfers.removeAll()
        connectedHost = nil
        connectedUsername = ""
        homePath = ""
        currentPath = ""
        entries = []
        selectedNames.removeAll()
        isFileOperationInProgress = false
        overwriteRequest = nil
        pendingOverwriteOperation = nil
        state = .disconnected
    }

    func toggleSelection(_ entry: SFTPDirectoryEntry, extending: Bool) {
        if extending {
            if !selectedNames.insert(entry.name).inserted { selectedNames.remove(entry.name) }
        } else {
            selectedNames = [entry.name]
        }
    }

    func selectAllVisible() {
        selectedNames = Set(visibleEntries.map(\.name))
    }

    var selectedEntries: [SFTPDirectoryEntry] {
        visibleEntries.filter { selectedNames.contains($0.name) }
    }

    func dragPayload(for entry: SFTPDirectoryEntry) -> SFTPRemoteDragPayload {
        let draggedEntries = selectedNames.contains(entry.name) ? selectedEntries : [entry]
        return SFTPRemoteDragPayload(
            sessionID: generation,
            sourceDirectory: currentPath,
            names: draggedEntries.map(\.name)
        )
    }

    func download(
        payloads: [SFTPRemoteDragPayload],
        to localDirectory: URL,
        completion: @escaping () -> Void = {}
    ) -> Bool {
        guard endingStatus == nil, state == .connected, !payloads.isEmpty,
              payloads.allSatisfy({
                  $0.sessionID == generation && $0.sourceDirectory == currentPath
              }) else { return false }
        let requestedNames = Set(payloads.flatMap(\.names))
        let matchingEntries = entries.filter { requestedNames.contains($0.name) }
        guard !matchingEntries.isEmpty,
              matchingEntries.count == requestedNames.count else { return false }
        download(entries: matchingEntries, to: localDirectory, completion: completion)
        return true
    }

    func upload(
        payloads: [SFTPLocalDragPayload],
        from localStore: LocalFileBrowserStore
    ) -> Bool {
        guard endingStatus == nil, state == .connected else { return false }
        let localEntries = localStore.entries(for: payloads)
        guard !localEntries.isEmpty else { return false }
        upload(localURLs: localEntries.map(\.url), to: currentPath)
        return true
    }

    func upload(localURLs: [URL], to destinationDirectory: String? = nil) {
        guard endingStatus == nil, client != nil, state == .connected, !localURLs.isEmpty,
              !isFileOperationInProgress, overwriteRequest == nil else { return }
        let remoteDirectory = destinationDirectory ?? currentPath
        guard remoteDirectory == currentPath else {
            errorMessage = "請先開啟要上傳的遠端目錄，再加入傳輸。"
            return
        }
        // Do not queue a blocking remote preflight behind a large transfer: every
        // requested transfer must become visible/cancellable immediately. The
        // client rechecks the actual destination before publication.
        let names = Set(localURLs.map(\.lastPathComponent))
        let conflicts = entries.filter { names.contains($0.name) }.map(\.name)
        if conflicts.isEmpty {
            performUpload(localURLs: localURLs, to: remoteDirectory, overwrite: false)
        } else {
            pendingOverwriteOperation = .upload(urls: localURLs, remoteDirectory: remoteDirectory, sessionID: generation)
            overwriteRequest = SFTPOverwriteRequest(id: UUID(), direction: .upload, names: conflicts.sorted())
        }
    }

    private func performUpload(localURLs: [URL], to remoteDirectory: String, overwrite: Bool) {
        guard endingStatus == nil, client != nil, state == .connected else { return }
        for url in localURLs {
            enqueueTransfer(direction: .upload, name: url.lastPathComponent,
                source: url.path, destination: Self.appending(url.lastPathComponent, to: remoteDirectory),
                total: nil, operation: .upload(url, remoteDirectory, overwrite), completion: {})
        }
        startNextTransfer()
    }

    func download(
        entries: [SFTPDirectoryEntry],
        to localDirectory: URL,
        completion: @escaping () -> Void = {}
    ) {
        guard endingStatus == nil, state == .connected, !entries.isEmpty,
              !isFileOperationInProgress, overwriteRequest == nil else { return }
        let remoteDirectory = currentPath
        let conflicts = entries.map(\.name).filter {
            FileManager.default.fileExists(
                atPath: localDirectory.appending(path: $0).path
            )
        }
        if !conflicts.isEmpty {
            pendingOverwriteOperation = .download(
                entries: entries,
                remoteDirectory: remoteDirectory,
                localDirectory: localDirectory,
                sessionID: generation,
                completion: completion
            )
            overwriteRequest = SFTPOverwriteRequest(
                id: UUID(),
                direction: .download,
                names: conflicts.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            )
            return
        }
        performDownload(
            entries: entries,
            from: remoteDirectory,
            to: localDirectory,
            overwrite: false,
            completion: completion
        )
    }

    private func performDownload(
        entries: [SFTPDirectoryEntry], from remoteDirectory: String,
        to localDirectory: URL, overwrite: Bool, completion: @escaping () -> Void
    ) {
        guard endingStatus == nil, client != nil, state == .connected else { return }
        for entry in entries {
            enqueueTransfer(direction: .download, name: entry.name,
                source: Self.appending(entry.name, to: remoteDirectory),
                destination: localDirectory.appending(path: entry.name).path,
                total: entry.isDirectory ? nil : entry.attributes.size,
                operation: .download(entry, remoteDirectory, localDirectory, overwrite), completion: completion)
        }
        startNextTransfer()
    }

    @discardableResult private func enqueueTransfer(direction: SFTPTransferDirection, name: String, source: String,
                                 destination: String, total: UInt64?, operation: TransferWork.Operation,
                                 completion: @escaping () -> Void) -> UUID {
        let id = UUID()
        var item = SFTPTransferItem(id: id, direction: direction, name: name,
            completedBytes: 0, totalBytes: total, state: .waiting)
        item.targetDescription = connectedHost.map { "\($0.displayName) · \(connectedUsername)@\($0.hostname):\($0.port)" } ?? "SFTP"
        item.sourcePath = source
        item.destinationPath = destination
        transferItems.append(item)
        pendingTransfers.append(TransferWork(id: id, generation: generation, operation: operation, completion: completion))
        return id
    }

    func enqueueEdit(_ id: UUID, snapshot: SFTPEditSnapshot, path: String, baseline: SFTPEditRevision) {
        let transfer = enqueueTransfer(direction: .upload, name: "回存 · \(snapshot.url.lastPathComponent)",
            source: snapshot.url.path, destination: path, total: snapshot.size,
            operation: .edit(id, snapshot, path, baseline), completion: {})
        editTransferIDs[transfer] = id
        startNextTransfer()
    }

    func enqueueEditCheck(_ id: UUID, path: String) {
        let transfer = enqueueTransfer(direction: .download, name: "核對編輯檔案 · \((path as NSString).lastPathComponent)",
            source: path, destination: "", total: nil, operation: .editCheck(id, path), completion: {})
        editTransferIDs[transfer] = id
        startNextTransfer()
    }

    func cancelEditTransfers(_ id: UUID) {
        for transfer in editTransferIDs.filter({ $0.value == id }).map(\.key) { cancelTransfer(transfer) }
    }

    private func completeEditing(_ work: TransferWork, failure: Error?, revision: SFTPEditRevision?) {
        editTransferIDs.removeValue(forKey: work.id)
        switch work.operation {
        case .edit(let id, _, _, _):
            editStore.completed(id, result: failure.map(Result.failure) ?? .success(()), generation: work.generation)
        case .editCheck(let id, _):
            editStore.checked(id, result: revision.map(Result.success) ?? .failure(failure ?? SFTPEditError.conflict), generation: work.generation)
        default: break
        }
    }

    func resumeEdit(_ id: UUID) {
        guard endingStatus == nil else { return }
        guard let target = editingTarget else { errorMessage = SFTPEditError.differentConnection.localizedDescription; return }
        do { editStore.resume(id, connection: self, trust: try editingTrust(target)) }
        catch { errorMessage = error.localizedDescription }
    }

    func existingEdit(for entry: SFTPDirectoryEntry) -> SFTPEditWork? {
        guard let target = editingTarget else { return nil }
        return editStore.existing(target: target, path: Self.appending(entry.name, to: currentPath))
    }

    /// Called before either picker/confirmation and again at the enqueue boundary.
    /// Duplicate invocations reveal the existing work and never launch another editor.
    func revealPreparingCopy(of entry: SFTPDirectoryEntry) -> Bool {
        guard let target = editingTarget,
              editStore.isPreparing(target: target, path: Self.appending(entry.name, to: currentPath)) else { return false }
        preparationRevealToken = UUID()
        return true
    }

    func prepareEditingCopy(of entry: SFTPDirectoryEntry,
                            completion: @escaping (Result<SFTPEditWork, Error>) -> Void) {
        prepareFile(entry, editCompletion: completion, previewCompletion: nil)
    }

    private func prepareFile(_ entry: SFTPDirectoryEntry,
                             editCompletion: ((Result<SFTPEditWork, Error>) -> Void)?,
                             previewCompletion: ((Result<URL, Error>) -> Void)?) {
        func reject(_ error: Error) { editCompletion?(.failure(error)); previewCompletion?(.failure(error)) }
        guard let target = editingTarget else { reject(SFTPEditError.differentConnection); return }
        if revealPreparingCopy(of: entry) { return }
        guard endingStatus == nil, !isFileOperationInProgress, overwriteRequest == nil else {
            reject(SFTPEditError.operationInProgress); return
        }
        guard entry.attributes.kind == .regularFile else { reject(SFTPEditError.unstableFile); return }
        if let existing = existingEdit(for: entry), let editCompletion { editCompletion(.success(existing)); return }
        let path = Self.appending(entry.name, to: currentPath)
        guard SFTPExternalEditStore.validPath(path) else { reject(SFTPEditError.unstableFile); return }
        let id = UUID()
        let trust: String?
        do { trust = editCompletion == nil ? nil : try editingTrust(target) }
        catch { reject(error); return }
        guard editStore.reserve(id, target: target, path: path) else { preparationRevealToken = UUID(); return }
        let localURL = editCompletion == nil ? nil : editStore.directory(id)
            .appendingPathComponent("content", isDirectory: true).appendingPathComponent(entry.name)
        let preparation = FilePreparation(id: id, target: target, entry: entry,
            remoteDirectory: currentPath, hostName: connectedHost?.displayName ?? target.hostname,
            trust: trust, localURL: localURL, editCompletion: editCompletion, previewCompletion: previewCompletion, path: path)
        let total: UInt64?
        if let size = entry.attributes.size, editCompletion != nil {
            let (value, overflow) = size.multipliedReportingOverflow(by: 2)
            total = overflow ? nil : value
        } else { total = entry.attributes.size }
        let transfer = enqueueTransfer(direction: .download, name: "開啟檔案 · \(entry.name)",
            source: path, destination: localURL?.path ?? "本機副本", total: total,
            operation: .prepare(preparation), completion: {})
        editTransferIDs[transfer] = id
        preparationRevealToken = UUID()
        startNextTransfer()
    }

    /// Only undelivered preparation files are owned by this cleanup path.
    private func finishPreparation(_ work: TransferWork, failure: Error?, revision: SFTPEditRevision?,
                                   temporaryURL: URL?) -> Error? {
        guard case .prepare(let request) = work.operation else { return failure }
        defer { editStore.releasePreparation(request.id); editTransferIDs.removeValue(forKey: work.id) }
        var error = failure
        if generation != work.generation || editingTarget != request.target || endingStatus != nil { error = SFTPConnectionError.cancelled }
        if error == nil {
            do {
                if let revision, let trust = request.trust, request.localURL != nil {
                    let edit = try editStore.register(id: request.id, target: request.target,
                        hostName: request.hostName, path: request.path, trust: trust, baseline: revision, connection: self)
                    request.editCompletion?(.success(edit))
                } else if let temporaryURL {
                    request.previewCompletion?(.success(temporaryURL))
                } else { throw SFTPEditError.unstableFile }
                return nil
            } catch let caught { error = caught }
        }
        if request.localURL != nil { try? FileManager.default.removeItem(at: editStore.directory(request.id)) }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent()) }
        if generation == work.generation, let error {
            request.editCompletion?(.failure(error)); request.previewCompletion?(.failure(error))
        }
        return error
    }

    func cancelTransfer(_ id: UUID) {
        guard let index = transferItems.firstIndex(where: { $0.id == id }) else { return }
        if activeTransferID == id {
            if transferCancellation?.cancel() == true { transferItems[index].state = .cancelling }
        } else if transferItems[index].state == .waiting {
            if let work = pendingTransfers.first(where: { $0.id == id }) {
                _ = finishPreparation(work, failure: SFTPConnectionError.cancelled, revision: nil, temporaryURL: nil)
                completeEditing(work, failure: SFTPConnectionError.cancelled, revision: nil)
            }
            pendingTransfers.removeAll { $0.id == id }
            finishTransfer(id, state: .cancelled)
            trimTransferHistory()
        }
    }

    func cancelAllTransfers() {
        pendingOverwriteOperation = nil
        overwriteRequest = nil
        for id in transferItems.filter({ !$0.state.isFinished }).map(\.id) { cancelTransfer(id) }
    }

    private func startNextTransfer() {
        guard endingStatus == nil, activeTransferID == nil, let client, state == .connected,
              !isFileOperationInProgress, overwriteRequest == nil else { return }
        pendingTransfers.removeAll { $0.generation != generation }
        guard !pendingTransfers.isEmpty else { return }
        let work = pendingTransfers.removeFirst()
        let cancellation = SFTPTransferCancellation()
        activeTransferID = work.id
        transferCancellation = cancellation
        if case .edit(let id, _, _, _) = work.operation { editStore.started(id) }
        if let index = transferItems.firstIndex(where: { $0.id == work.id }) {
            transferItems[index].state = .transferring
            transferItems[index].timing.start(now: ProcessInfo.processInfo.systemUptime, date: Date())
        }
        Task {
            var failure: Error?
            var checkedRevision: SFTPEditRevision?
            var preparedURL: URL?
            do {
                let finalProgress = try await Task.detached(priority: .userInitiated) { [weak self] in
                    var lastUpdate = -Double.infinity
                    var finalBytes: UInt64 = 0
                    var finalTotal: UInt64?
                    var revision: SFTPEditRevision?
                    var previewURL: URL?
                    let progress: (UInt64, UInt64?) -> Void = { completed, total in
                        finalBytes = completed; finalTotal = total
                        let now = ProcessInfo.processInfo.systemUptime
                        guard completed == 0 || total == completed || now - lastUpdate >= 0.2 else { return }
                        lastUpdate = now
                        DispatchQueue.main.async { [weak self] in
                            self?.updateTransfer(work.id, completed: completed, total: total)
                        }
                    }
                    var lastPhase: SFTPPreparationPhase?
                    let preparing: (SFTPPreparationPhase, UInt64, UInt64?) -> Void = { phase, bytes, total in
                        if lastPhase != phase {
                            lastPhase = phase
                            DispatchQueue.main.async { [weak self] in self?.updatePreparationPhase(work.id, phase: phase) }
                            lastUpdate = -Double.infinity
                        }
                        progress(bytes, total)
                    }
                    switch work.operation {
                    case .upload(let url, let remoteDirectory, let overwrite):
                        try client.uploadItem(at: url, to: remoteDirectory, overwrite: overwrite,
                            cancellation: cancellation, progress: progress)
                    case .download(let entry, let remoteDirectory, let localDirectory, let overwrite):
                        try client.downloadItem(entry, from: remoteDirectory, to: localDirectory,
                            overwrite: overwrite, cancellation: cancellation, progress: progress)
                    case .edit(_, let snapshot, let path, let baseline):
                        try client.uploadItem(at: snapshot.url, to: (path as NSString).deletingLastPathComponent,
                            overwrite: true, cancellation: cancellation, editingBaseline: baseline, progress: progress)
                    case .editCheck(_, let path):
                        revision = try client.editingRevision(at: path, cancellation: cancellation) { preparing(.verification, $0, $1) }
                    case .prepare(let request):
                        if let localURL = request.localURL {
                            try cancellation.check()
                            try SFTPEditFileMonitor.privateDirectory(localURL.deletingLastPathComponent())
                            revision = try client.downloadEditingCopy(at: request.path, to: localURL,
                                cancellation: cancellation, progress: preparing)
                        } else {
                            previewURL = try client.downloadTemporaryCopy(request.entry, from: request.remoteDirectory,
                                cancellation: cancellation) { preparing(.download, $0, $1) }
                        }
                    }
                    return (finalBytes, finalTotal, revision, previewURL)
                }.value
                updateTransfer(work.id, completed: finalProgress.0, total: finalProgress.1)
                checkedRevision = finalProgress.2
                preparedURL = finalProgress.3
                if case .prepare = work.operation { try cancellation.check() }
            } catch { failure = error }
            failure = finishPreparation(work, failure: failure, revision: checkedRevision, temporaryURL: preparedURL)
            if let failure {
                if case SFTPConnectionError.cancelled = failure {
                    finishTransfer(work.id, state: .cancelled)
                } else if failure is SFTPTransferError {
                    if case SFTPTransferError.unsafeOverwrite = failure {
                        finishTransfer(work.id, state: .failed(failure.localizedDescription))
                    } else {
                        finishTransfer(work.id, state: .needsAttention(failure.localizedDescription))
                        // Ambiguous transport/publication state must not feed the next job.
                        if generation == work.generation { disconnect() }
                    }
                } else {
                    finishTransfer(work.id, state: .failed(Self.friendlyMessage(for: failure)))
                    if let error = failure as? SFTPProtocolError, generation == work.generation {
                        switch error {
                        case .serverStatus: break
                        default: disconnect()
                        }
                    }
                    if let error = failure as? SFTPConnectionError,
                       generation == work.generation {
                        switch error {
                        case .timedOut, .connectionClosed: disconnect()
                        default: break
                        }
                    }
                }
            } else {
                finishTransfer(work.id, state: .completed)
            }
            completeEditing(work, failure: failure, revision: checkedRevision)
            if activeTransferID == work.id {
                activeTransferID = nil
                transferCancellation = nil
            }
            if generation == work.generation { work.completion() }
            trimTransferHistory()
            startNextTransfer()
            if generation == work.generation, !hasActiveTransfers { reload() }
        }
    }

    private func updatePreparationPhase(_ id: UUID, phase: SFTPPreparationPhase) {
        guard let index = transferItems.firstIndex(where: { $0.id == id }), !transferItems[index].state.isFinished else { return }
        transferItems[index].preparationPhase = phase
    }

    private func finishTransfer(_ id: UUID, state: SFTPTransferState) {
        guard let index = transferItems.firstIndex(where: { $0.id == id }) else { return }
        transferItems[index].state = state
        transferItems[index].timing.finish(now: ProcessInfo.processInfo.systemUptime, date: Date())
        if state == .completed, let total = transferItems[index].totalBytes {
            transferItems[index].completedBytes = total
        }
    }

    private func trimTransferHistory() {
        let finished = transferItems.filter { $0.state.isFinished }
        let evicted = Set(finished.prefix(max(0, finished.count - 200)).map(\.id))
        transferItems.removeAll { evicted.contains($0.id) }
    }

    func confirmOverwrite() {
        guard let operation = pendingOverwriteOperation else {
            overwriteRequest = nil
            return
        }
        pendingOverwriteOperation = nil
        overwriteRequest = nil
        switch operation {
        case .upload(let urls, let remoteDirectory, let sessionID):
            guard sessionID == generation else { return }
            performUpload(localURLs: urls, to: remoteDirectory, overwrite: true)
        case .download(
            let entries,
            let remoteDirectory,
            let localDirectory,
            let sessionID,
            let completion
        ):
            guard sessionID == generation else { return }
            performDownload(
                entries: entries,
                from: remoteDirectory,
                to: localDirectory,
                overwrite: true,
                completion: completion
            )
        }
    }

    func cancelOverwrite() {
        pendingOverwriteOperation = nil
        overwriteRequest = nil
        startNextTransfer()
    }

    func createDirectory(named input: String) {
        guard endingStatus == nil, let client, state == .connected else { return }
        do {
            let name = try Self.validatedName(input)
            let target = Self.appending(name, to: currentPath)
            performFileOperation { try client.createDirectory(target) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ entry: SFTPDirectoryEntry, to input: String) {
        guard endingStatus == nil, let client, state == .connected else { return }
        do {
            let name = try Self.validatedName(input)
            let oldName = try Self.validatedName(entry.name)
            let oldPath = Self.appending(oldName, to: currentPath)
            let newPath = Self.appending(name, to: currentPath)
            performFileOperation { try client.rename(from: oldPath, to: newPath) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setPermissions(_ permissions: UInt32, for entry: SFTPDirectoryEntry) {
        guard endingStatus == nil, let client, state == .connected else { return }
        do {
            let name = try Self.validatedName(entry.name)
            let path = Self.appending(name, to: currentPath)
            performFileOperation { try client.setPermissions(permissions, at: path) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() {
        guard endingStatus == nil, let client, state == .connected else { return }
        let targets: [(String, SFTPFileKind)]
        do {
            targets = try selectedEntries.map {
                let name = try Self.validatedName($0.name)
                return (Self.appending(name, to: currentPath), $0.attributes.kind)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !targets.isEmpty else { return }
        performFileOperation {
            for target in targets {
                try client.removeRecursively(path: target.0, kind: target.1)
            }
        }
    }

    func prepareTemporaryCopy(
        of entry: SFTPDirectoryEntry,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        prepareFile(entry, editCompletion: nil, previewCompletion: completion)
    }

    func clearCompletedTransfers() {
        transferItems.removeAll { $0.state.isFinished }
    }

    private func load(path: String) {
        guard endingStatus == nil, let client else { return }
        let request = UUID()
        directoryRequest = request
        let generation = self.generation
        state = .connecting
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try client.listDirectory(path)
                }.value
                guard self.generation == generation, directoryRequest == request else { return }
                currentPath = path
                entries = result
                selectedNames.removeAll()
                state = .connected
                startNextTransfer()
            } catch {
                guard self.generation == generation, directoryRequest == request else { return }
                state = .connected
                startNextTransfer()
                errorMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    private func performFileOperation(_ operation: @escaping @Sendable () throws -> Void) {
        guard endingStatus == nil else { return }
        isFileOperationInProgress = true
        errorMessage = nil
        let sessionID = generation
        Task {
            do {
                try await Task.detached(priority: .userInitiated, operation: operation).value
                guard generation == sessionID else { return }
                isFileOperationInProgress = false
                selectedNames.removeAll()
                reload()
            } catch {
                guard generation == sessionID else { return }
                isFileOperationInProgress = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateTransfer(
        _ id: UUID,
        completed: UInt64? = nil,
        total: UInt64? = nil,
        state: SFTPTransferState? = nil
    ) {
        guard let index = transferItems.firstIndex(where: { $0.id == id }),
              !transferItems[index].state.isFinished else { return }
        if let completed {
            transferItems[index].completedBytes = completed
            transferItems[index].timing.record(bytes: completed, now: ProcessInfo.processInfo.systemUptime)
        }
        if let total { transferItems[index].totalBytes = total }
        if let state { transferItems[index].state = state }
    }

    private static func appending(_ name: String, to path: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }

    nonisolated private static func validatedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SFTPFileOperationError.unsafeName(name)
        }
        return name
    }

    private static func friendlyMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("subsystem request failed") ||
            message.localizedCaseInsensitiveContains("subsystem request for sftp failed") {
            return "這台主機沒有啟用 SFTP 子系統。SSH 終端仍可能正常使用。"
        }
        if message.localizedCaseInsensitiveContains("host key verification failed") {
            return "尚未信任這台主機的 SSH 指紋，或主機指紋已變更。請先用一般 SSH 連線確認指紋，再開啟 SFTP。"
        }
        return message
    }
}
