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
    static var legacyHostsBackupFile: URL { rootDirectory.appending(path: "hosts-v0.1-backup.json") }
    static var preHierarchyBackupFile: URL { rootDirectory.appending(path: "hosts-v0.6-pre-hierarchy-backup.json") }
    static var knownHostsFile: URL { rootDirectory.appending(path: "known_hosts") }
    static var importedKnownHostsRawFile: URL { rootDirectory.appending(path: "known_hosts-imported") }
    static var importedKnownHostsIndexFile: URL { rootDirectory.appending(path: "known-hosts-import.json") }
    static var importBackupsDirectory: URL { rootDirectory.appending(path: "Import Backups", directoryHint: .isDirectory) }
    static var authenticationLogsDirectory: URL { rootDirectory.appending(path: "Authentication Logs", directoryHint: .isDirectory) }
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

    static func createAuthenticationLog() throws -> URL {
        try prepare()
        try FileManager.default.createDirectory(
            at: authenticationLogsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: authenticationLogsDirectory.path
        )
        let url = authenticationLogsDirectory.appending(path: "ssh-auth-\(UUID().uuidString).log")
        try Data().write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func removeAuthenticationLog(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
