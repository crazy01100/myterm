import Foundation

enum AppPaths {
    static let rootDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configuredName = Bundle.main.object(
            forInfoDictionaryKey: "MyTermApplicationSupportDirectory"
        ) as? String
        let directoryName = configuredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.appending(
            path: directoryName?.isEmpty == false ? directoryName! : "MySSHClient",
            directoryHint: .isDirectory
        )
    }()

    static var hostsFile: URL { rootDirectory.appending(path: "hosts.json") }
    static var hostConnectionRecencyFile: URL {
        rootDirectory.appending(path: "host-connection-recency.json")
    }
    static var connectionAuditLogFile: URL {
        rootDirectory.appending(path: "connection-audit-log.json")
    }
    static var legacyHostsBackupFile: URL { rootDirectory.appending(path: "hosts-v0.1-backup.json") }
    static var preHierarchyBackupFile: URL { rootDirectory.appending(path: "hosts-v0.6-pre-hierarchy-backup.json") }
    static var knownHostsFile: URL { rootDirectory.appending(path: "known_hosts") }
    static var importedKnownHostsRawFile: URL { rootDirectory.appending(path: "known_hosts-imported") }
    static var importedKnownHostsIndexFile: URL { rootDirectory.appending(path: "known-hosts-import.json") }
    static var importBackupsDirectory: URL { rootDirectory.appending(path: "Import Backups", directoryHint: .isDirectory) }
    static var sshConnectionLogsDirectory: URL { rootDirectory.appending(path: "Authentication Logs", directoryHint: .isDirectory) }
    static var syncDirectory: URL { rootDirectory.appending(path: "Sync", directoryHint: .isDirectory) }
    static var syncMutationJournalFile: URL { syncDirectory.appending(path: "mutation-journal.json") }
    static var syncDeviceIdentityFile: URL { syncDirectory.appending(path: "device-id") }
    static var syncBackupsDirectory: URL { rootDirectory.appending(path: "Sync Backups", directoryHint: .isDirectory) }

    static func syncBaselineFile(ownerUIDDigest: String) -> URL {
        syncDirectory.appending(path: "metadata-baseline-\(ownerUIDDigest).json")
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
        if !FileManager.default.fileExists(atPath: knownHostsFile.path) {
            FileManager.default.createFile(atPath: knownHostsFile.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        if !FileManager.default.fileExists(atPath: importedKnownHostsRawFile.path) {
            FileManager.default.createFile(atPath: importedKnownHostsRawFile.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    static func createSSHConnectionLog() throws -> URL {
        try prepare()
        try FileManager.default.createDirectory(
            at: sshConnectionLogsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sshConnectionLogsDirectory.path
        )
        let url = sshConnectionLogsDirectory.appending(path: "ssh-connection-\(UUID().uuidString).log")
        try Data().write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func removeSSHConnectionLog(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    static func removeStaleSSHConnectionLogs(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Int {
        let directory = directory ?? sshConnectionLogsDirectory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return 0 }

        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("ssh-connection-"), candidate.pathExtension == "log" else {
                continue
            }
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            try fileManager.removeItem(at: candidate)
            removedCount += 1
        }
        return removedCount
    }
}
