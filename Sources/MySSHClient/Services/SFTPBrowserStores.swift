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
final class SFTPRemoteBrowserStore: ObservableObject, SFTPHostOpeningConnection {
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
    private var connectionCancellation: SFTPCancellation?
    private var generation = UUID()
    private var pendingOverwriteOperation: PendingOverwriteOperation?

    private struct TransferWork {
        enum Operation {
            case upload(URL, String, Bool)
            case download(SFTPDirectoryEntry, String, URL, Bool)
        }
        let id: UUID
        let generation: UUID
        let operation: Operation
        let completion: () -> Void
    }
    private var pendingTransfers: [TransferWork] = []
    private var activeTransferID: UUID?
    private var transferCancellation: SFTPTransferCancellation?

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
        client = connection
        connectedHost = host
        connectedUsername = host.username
        currentPath = "/"
        homePath = "/"
        state = .connected
    }
#endif

    var visibleEntries: [SFTPDirectoryEntry] {
        showHiddenFiles ? entries : entries.filter { !$0.isHidden }
    }

    var openingSnapshot: SFTPConnectionSnapshot {
        let active = state == .connected || state == .connecting
        let target = active ? connectedHost.map { SFTPConnectionTarget(host: $0, username: connectedUsername) } : nil
        let transfersPending = hasActiveTransfers
        return SFTPConnectionSnapshot(target: target, generation: generation,
            isBusy: transfersPending || isFileOperationInProgress || overwriteRequest != nil || pendingOverwriteOperation != nil,
            description: connectedHost.map { "\($0.displayName)（\(connectedUsername)@\($0.hostname):\($0.port)）" } ?? "SFTP")
    }

    func connect(to host: HostProfile, username: String) {
        disconnect()
        let generation = UUID()
        self.generation = generation
        let cancellation = SFTPCancellation()
        connectionCancellation = cancellation
        state = .connecting
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
                startNextTransfer()
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
        guard client != nil, state == .connected, !localURLs.isEmpty,
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
        guard client != nil, state == .connected else { return }
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
        guard state == .connected, !entries.isEmpty,
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
        guard client != nil, state == .connected else { return }
        for entry in entries {
            enqueueTransfer(direction: .download, name: entry.name,
                source: Self.appending(entry.name, to: remoteDirectory),
                destination: localDirectory.appending(path: entry.name).path,
                total: entry.isDirectory ? nil : entry.attributes.size,
                operation: .download(entry, remoteDirectory, localDirectory, overwrite), completion: completion)
        }
        startNextTransfer()
    }

    private func enqueueTransfer(direction: SFTPTransferDirection, name: String, source: String,
                                 destination: String, total: UInt64?, operation: TransferWork.Operation,
                                 completion: @escaping () -> Void) {
        let id = UUID()
        var item = SFTPTransferItem(id: id, direction: direction, name: name,
            completedBytes: 0, totalBytes: total, state: .waiting)
        item.targetDescription = connectedHost.map { "\($0.displayName) · \(connectedUsername)@\($0.hostname):\($0.port)" } ?? "SFTP"
        item.sourcePath = source
        item.destinationPath = destination
        transferItems.append(item)
        pendingTransfers.append(TransferWork(id: id, generation: generation, operation: operation, completion: completion))
    }

    func cancelTransfer(_ id: UUID) {
        guard let index = transferItems.firstIndex(where: { $0.id == id }) else { return }
        if activeTransferID == id {
            if transferCancellation?.cancel() == true { transferItems[index].state = .cancelling }
        } else if transferItems[index].state == .waiting {
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
        guard activeTransferID == nil, let client, state == .connected,
              !isFileOperationInProgress, overwriteRequest == nil else { return }
        pendingTransfers.removeAll { $0.generation != generation }
        guard !pendingTransfers.isEmpty else { return }
        let work = pendingTransfers.removeFirst()
        let cancellation = SFTPTransferCancellation()
        activeTransferID = work.id
        transferCancellation = cancellation
        if let index = transferItems.firstIndex(where: { $0.id == work.id }) {
            transferItems[index].state = .transferring
            transferItems[index].timing.start(now: ProcessInfo.processInfo.systemUptime, date: Date())
        }
        Task {
            var failure: Error?
            do {
                let finalProgress = try await Task.detached(priority: .userInitiated) { [weak self] in
                    var lastUpdate = -Double.infinity
                    var finalBytes: UInt64 = 0
                    var finalTotal: UInt64?
                    let progress: (UInt64, UInt64?) -> Void = { completed, total in
                        finalBytes = completed; finalTotal = total
                        let now = ProcessInfo.processInfo.systemUptime
                        guard completed == 0 || total == completed || now - lastUpdate >= 0.2 else { return }
                        lastUpdate = now
                        DispatchQueue.main.async { [weak self] in
                            self?.updateTransfer(work.id, completed: completed, total: total)
                        }
                    }
                    switch work.operation {
                    case .upload(let url, let remoteDirectory, let overwrite):
                        try client.uploadItem(at: url, to: remoteDirectory, overwrite: overwrite,
                            cancellation: cancellation, progress: progress)
                    case .download(let entry, let remoteDirectory, let localDirectory, let overwrite):
                        try client.downloadItem(entry, from: remoteDirectory, to: localDirectory,
                            overwrite: overwrite, cancellation: cancellation, progress: progress)
                    }
                    return (finalBytes, finalTotal)
                }.value
                updateTransfer(work.id, completed: finalProgress.0, total: finalProgress.1)
            } catch { failure = error }
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
        let sessionID = generation
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
            guard generation == sessionID else {
                if case .success(let url) = result { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                return
            }
            isFileOperationInProgress = false
            completion(result)
        }
    }

    func clearCompletedTransfers() {
        transferItems.removeAll { $0.state.isFinished }
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
                startNextTransfer()
            } catch {
                guard self.generation == generation else { return }
                state = .connected
                startNextTransfer()
                errorMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    private func performFileOperation(_ operation: @escaping @Sendable () throws -> Void) {
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
