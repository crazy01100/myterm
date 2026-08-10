import Foundation

enum SyncDeviceIdentityStoreError: LocalizedError, Equatable {
    case invalidFile

    var errorDescription: String? {
        "這台 Mac 的同步裝置識別資料格式不正確。"
    }
}

/// A random, non-secret identifier used only for encrypted record revision
/// metadata. It deliberately contains no hardware serial number, user name,
/// Apple ID, Firebase token, host field, or Keychain secret.
struct SyncDeviceIdentityStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = AppPaths.syncDeviceIdentityFile) {
        self.fileURL = fileURL
    }

    func loadOrCreate() throws -> UUID {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 128,
                  let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let id = UUID(uuidString: value) else {
                throw SyncDeviceIdentityStoreError.invalidFile
            }
            return id
        }

        let id = UUID()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data((id.uuidString.lowercased() + "\n").utf8)
            .write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return id
    }
}
