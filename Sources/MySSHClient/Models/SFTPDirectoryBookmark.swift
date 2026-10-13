import Foundation

struct SFTPBookmarkTarget: Codable, Equatable, Hashable, Sendable {
    let hostID: UUID
    let hostname: String
    let port: Int
    let username: String

    func validated() throws -> Self {
        guard !hostname.isEmpty, hostname.utf8.count <= 1024, (1...65535).contains(port),
              !username.isEmpty, username.utf8.count <= 1024,
              !hostname.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BookmarkError.invalid }
        return self
    }
}

enum BookmarkError: LocalizedError {
    case invalid, duplicate, changed, unreadable, unsupportedVersion, limit
    var errorDescription: String? {
        switch self {
        case .invalid: "書籤名稱或目錄路徑無效。"
        case .duplicate: "這個目錄已加入書籤。"
        case .changed: "書籤、帳號或連線已變更，請重新開啟後再操作。"
        case .unreadable: "書籤資料無法讀寫；原有檔案已保留。"
        case .unsupportedVersion: "書籤資料來自較新的版本；已停止寫入並保留原檔。"
        case .limit: "書籤已達容量上限；原有內容已保留。"
        }
    }
}

enum BookmarkValidation {
    static func name(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100,
              !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BookmarkError.invalid }
        return clean
    }
    static func path(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 16 * 1024,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BookmarkError.invalid }
    }
}

struct LocalDirectoryBookmark: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    let path: String
    func validated() throws -> Self {
        var value = self; value.title = try BookmarkValidation.name(title)
        try BookmarkValidation.path(path)
        return value
    }
}

// Only this type is accepted by the sync codec. Local paths cannot enter a
// remote payload by serializing the entire on-disk library.
struct RemoteDirectoryBookmark: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    let path: String
    let target: SFTPBookmarkTarget
    func validated() throws -> Self {
        var value = self; value.title = try BookmarkValidation.name(title)
        try BookmarkValidation.path(path); _ = try target.validated()
        return value
    }
    func sameLocation(as other: Self) -> Bool { target == other.target && path == other.path }
}
