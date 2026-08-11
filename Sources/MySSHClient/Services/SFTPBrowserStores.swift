import Foundation

@MainActor
final class LocalFileBrowserStore: ObservableObject {
    @Published private(set) var currentURL: URL
    @Published private(set) var entries: [LocalFileEntry] = []
    @Published private(set) var isLoading = false
    @Published var showHiddenFiles = false
    @Published var selectedURLs: Set<URL> = []
    @Published var errorMessage: String?

    private var backHistory: [URL] = []
    private var forwardHistory: [URL] = []
    private var loadGeneration = UUID()

    init(fileManager: FileManager = .default) {
        currentURL = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        reload()
    }

    var visibleEntries: [LocalFileEntry] {
        showHiddenFiles ? entries : entries.filter { !$0.isHidden }
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
        backHistory.append(currentURL)
        forwardHistory.removeAll()
        currentURL = target
        selectedURLs.removeAll()
        reload()
    }

    func goBack() {
        guard let target = backHistory.popLast() else { return }
        forwardHistory.append(currentURL)
        currentURL = target
        selectedURLs.removeAll()
        reload()
    }

    func goForward() {
        guard let target = forwardHistory.popLast() else { return }
        backHistory.append(currentURL)
        currentURL = target
        selectedURLs.removeAll()
        reload()
    }

    func reload() {
        let generation = UUID()
        loadGeneration = generation
        let url = currentURL
        isLoading = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.loadEntries(at: url)
                }.value
                guard loadGeneration == generation else { return }
                entries = result
                selectedURLs = selectedURLs.intersection(Set(result.map(\.url)))
                isLoading = false
            } catch {
                guard loadGeneration == generation else { return }
                entries = []
                selectedURLs.removeAll()
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
        entries.filter { selectedURLs.contains($0.url) }
    }

    func dragPayload(for entry: LocalFileEntry) -> SFTPLocalDragPayload {
        let draggedEntries = selectedURLs.contains(entry.url) ? selectedEntries : [entry]
        return SFTPLocalDragPayload(
            paths: draggedEntries.map { $0.url.standardizedFileURL.path }
        )
    }

    func entries(for payloads: [SFTPLocalDragPayload]) -> [LocalFileEntry] {
        let requestedPaths = Set(payloads.flatMap(\.paths))
        return entries.filter { requestedPaths.contains($0.url.standardizedFileURL.path) }
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
            .sorted {
                if $0.isNavigableDirectory != $1.isNavigableDirectory {
                    return $0.isNavigableDirectory
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
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
final class SFTPRemoteBrowserStore: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var connectedHost: HostProfile?
    @Published private(set) var connectedUsername = ""
    @Published private(set) var homePath = ""
    @Published private(set) var currentPath = ""
    @Published private(set) var entries: [SFTPDirectoryEntry] = []
    @Published var showHiddenFiles = false
    @Published var selectedNames: Set<String> = []
    @Published var errorMessage: String?
    @Published private(set) var transferItems: [SFTPTransferItem] = []
    @Published private(set) var isFileOperationInProgress = false
    @Published private(set) var overwriteRequest: SFTPOverwriteRequest?

    private var client: SFTPClient?
    private var generation = UUID()
    private var pendingOverwriteOperation: PendingOverwriteOperation?

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

    var visibleEntries: [SFTPDirectoryEntry] {
        showHiddenFiles ? entries : entries.filter { !$0.isHidden }
    }

    func connect(to host: HostProfile, username: String) {
        disconnect()
        let generation = UUID()
        self.generation = generation
        state = .connecting
        connectedHost = host
        connectedUsername = username
        errorMessage = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let client = try SFTPClient.connect(to: host, username: username)
                    do {
                        let path = try client.realPath(".")
                        let entries = try client.listDirectory(path)
                        return (client, path, Self.sorted(entries))
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
            } catch {
                guard self.generation == generation else { return }
                client = nil
                entries = []
                selectedNames.removeAll()
                state = .failed
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
        guard state == .connected, currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        load(path: parent.isEmpty ? "/" : parent)
    }

    func goToPathComponent(_ path: String) {
        guard state == .connected else { return }
        load(path: path)
    }

    func reload() {
        guard state == .connected else { return }
        load(path: currentPath)
    }

    func disconnect() {
        generation = UUID()
        client?.close()
        client = nil
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
        entries.filter { selectedNames.contains($0.name) }
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
        guard state == .connected, !payloads.isEmpty,
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
        guard state == .connected else { return false }
        let localEntries = localStore.entries(for: payloads)
        guard !localEntries.isEmpty else { return false }
        upload(localURLs: localEntries.map(\.url), to: currentPath)
        return true
    }

    func upload(localURLs: [URL], to destinationDirectory: String? = nil) {
        guard let client, state == .connected, !localURLs.isEmpty else { return }
        let remoteDirectory = destinationDirectory ?? currentPath
        let sessionID = generation
        let names = localURLs.map(\.lastPathComponent)
        isFileOperationInProgress = true
        Task {
            do {
                let conflicts = try await Task.detached(priority: .userInitiated) {
                    try client.existingItemNames(names, in: remoteDirectory)
                }.value
                guard generation == sessionID else { return }
                isFileOperationInProgress = false
                if conflicts.isEmpty {
                    performUpload(
                        localURLs: localURLs,
                        to: remoteDirectory,
                        overwrite: false
                    )
                } else {
                    pendingOverwriteOperation = .upload(
                        urls: localURLs,
                        remoteDirectory: remoteDirectory,
                        sessionID: sessionID
                    )
                    overwriteRequest = SFTPOverwriteRequest(
                        id: UUID(),
                        direction: .upload,
                        names: conflicts.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
                    )
                }
            } catch {
                guard generation == sessionID else { return }
                isFileOperationInProgress = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performUpload(
        localURLs: [URL],
        to remoteDirectory: String,
        overwrite: Bool
    ) {
        guard let client, state == .connected, !localURLs.isEmpty else { return }
        let jobs = localURLs.map { url in
            SFTPTransferItem(
                id: UUID(), direction: .upload, name: url.lastPathComponent,
                completedBytes: 0, totalBytes: nil, state: .waiting
            )
        }
        transferItems.append(contentsOf: jobs)
        Task {
            for (url, job) in zip(localURLs, jobs) {
                updateTransfer(job.id, state: .transferring)
                do {
                    try await Task.detached(priority: .userInitiated) { [weak self] in
                        try client.uploadItem(
                            at: url,
                            to: remoteDirectory,
                            overwrite: overwrite
                        ) { completed, total in
                            DispatchQueue.main.async {
                                self?.updateTransfer(job.id, completed: completed, total: total)
                            }
                        }
                    }.value
                    updateTransfer(job.id, state: .completed)
                } catch {
                    updateTransfer(job.id, state: .failed(error.localizedDescription))
                    if errorMessage == nil { errorMessage = error.localizedDescription }
                }
            }
            reload()
        }
    }

    func download(
        entries: [SFTPDirectoryEntry],
        to localDirectory: URL,
        completion: @escaping () -> Void = {}
    ) {
        guard state == .connected, !entries.isEmpty else { return }
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
        entries: [SFTPDirectoryEntry],
        from remoteDirectory: String,
        to localDirectory: URL,
        overwrite: Bool,
        completion: @escaping () -> Void
    ) {
        guard let client, state == .connected, !entries.isEmpty else { return }
        let jobs = entries.map { entry in
            SFTPTransferItem(
                id: UUID(), direction: .download, name: entry.name,
                completedBytes: 0,
                totalBytes: entry.isDirectory ? nil : entry.attributes.size,
                state: .waiting
            )
        }
        transferItems.append(contentsOf: jobs)
        Task {
            for (entry, job) in zip(entries, jobs) {
                updateTransfer(job.id, state: .transferring)
                do {
                    try await Task.detached(priority: .userInitiated) { [weak self] in
                        try client.downloadItem(
                            entry,
                            from: remoteDirectory,
                            to: localDirectory,
                            overwrite: overwrite
                        ) { completed, total in
                            DispatchQueue.main.async {
                                self?.updateTransfer(job.id, completed: completed, total: total)
                            }
                        }
                    }.value
                    updateTransfer(job.id, state: .completed)
                } catch {
                    updateTransfer(job.id, state: .failed(error.localizedDescription))
                    if errorMessage == nil { errorMessage = error.localizedDescription }
                }
            }
            completion()
        }
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
    }

    func createDirectory(named input: String) {
        guard let client, state == .connected else { return }
        do {
            let name = try Self.validatedName(input)
            let target = Self.appending(name, to: currentPath)
            performFileOperation { try client.createDirectory(target) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ entry: SFTPDirectoryEntry, to input: String) {
        guard let client, state == .connected else { return }
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
        guard let client, state == .connected else { return }
        do {
            let name = try Self.validatedName(entry.name)
            let path = Self.appending(name, to: currentPath)
            performFileOperation { try client.setPermissions(permissions, at: path) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() {
        guard let client, state == .connected else { return }
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
        guard let client, state == .connected else { return }
        let remoteDirectory = currentPath
        isFileOperationInProgress = true
        Task {
            let result: Result<URL, Error>
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try client.downloadTemporaryCopy(entry, from: remoteDirectory)
                }.value
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            isFileOperationInProgress = false
            completion(result)
        }
    }

    func clearCompletedTransfers() {
        transferItems.removeAll {
            if case .completed = $0.state { return true }
            return false
        }
    }

    private func load(path: String) {
        guard let client else { return }
        let generation = self.generation
        state = .connecting
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    Self.sorted(try client.listDirectory(path))
                }.value
                guard self.generation == generation else { return }
                currentPath = path
                entries = result
                selectedNames.removeAll()
                state = .connected
            } catch {
                guard self.generation == generation else { return }
                state = .connected
                errorMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    private func performFileOperation(_ operation: @escaping @Sendable () throws -> Void) {
        isFileOperationInProgress = true
        errorMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated, operation: operation).value
                isFileOperationInProgress = false
                selectedNames.removeAll()
                reload()
            } catch {
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
        guard let index = transferItems.firstIndex(where: { $0.id == id }) else { return }
        if let completed { transferItems[index].completedBytes = completed }
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

    nonisolated private static func sorted(_ entries: [SFTPDirectoryEntry]) -> [SFTPDirectoryEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
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
