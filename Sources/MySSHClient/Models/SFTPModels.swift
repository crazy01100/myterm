import Foundation

struct SFTPLocalDragPayload: Codable, Equatable, Sendable {
    let paths: [String]
}

struct SFTPRemoteDragPayload: Codable, Equatable, Sendable {
    let sessionID: UUID
    let sourceDirectory: String
    let names: [String]
}

struct SFTPOverwriteRequest: Identifiable, Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case upload
        case download

        var title: String { self == .upload ? "上傳" : "下載" }
    }

    let id: UUID
    let direction: Direction
    let names: [String]
}

enum SFTPFileKind: String, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other

    var title: String {
        switch self {
        case .directory: "資料夾"
        case .regularFile: "檔案"
        case .symbolicLink: "連結"
        case .other: "其他"
        }
    }
}

struct SFTPFileAttributes: Equatable, Sendable {
    var size: UInt64?
    var userID: UInt32?
    var groupID: UInt32?
    var permissions: UInt32?
    var accessTime: Date?
    var modificationTime: Date?

    var kind: SFTPFileKind {
        guard let permissions else { return .other }
        switch permissions & 0o170000 {
        case 0o040000: return .directory
        case 0o100000: return .regularFile
        case 0o120000: return .symbolicLink
        default: return .other
        }
    }
}

struct SFTPDirectoryEntry: Identifiable, Equatable, Sendable {
    var name: String
    var longName: String
    var attributes: SFTPFileAttributes

    var id: String { name }
    var isDirectory: Bool { attributes.kind == .directory }
    var isHidden: Bool { name.hasPrefix(".") && name != "." && name != ".." }
}

struct LocalFileEntry: Identifiable, Equatable, Sendable {
    var url: URL
    var isDirectory: Bool
    var isSymbolicLink: Bool
    var symbolicLinkTargetDirectoryURL: URL?
    var size: UInt64?
    var modificationDate: Date?
    var permissions: UInt32?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isHidden: Bool { name.hasPrefix(".") }
    var navigableDirectoryURL: URL? {
        if let symbolicLinkTargetDirectoryURL { return symbolicLinkTargetDirectoryURL }
        return isDirectory ? url : nil
    }
    var isNavigableDirectory: Bool { navigableDirectoryURL != nil }
    var kindTitle: String {
        if isSymbolicLink { return "連結" }
        return isDirectory ? "資料夾" : "檔案"
    }

    static func inspect(
        _ fileURL: URL,
        fileManager: FileManager = .default
    ) throws -> LocalFileEntry {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .isHiddenKey
        ]
        let values = try fileURL.resourceValues(forKeys: keys)
        let isSymbolicLink = values.isSymbolicLink == true
        let symbolicLinkTargetDirectoryURL: URL?
        if isSymbolicLink {
            let resolvedURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            let targetValues = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
            symbolicLinkTargetDirectoryURL = targetValues?.isDirectory == true
                ? resolvedURL
                : nil
        } else {
            symbolicLinkTargetDirectoryURL = nil
        }
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
        return LocalFileEntry(
            url: fileURL,
            isDirectory: values.isDirectory == true,
            isSymbolicLink: isSymbolicLink,
            symbolicLinkTargetDirectoryURL: symbolicLinkTargetDirectoryURL,
            size: values.fileSize.map(UInt64.init),
            modificationDate: values.contentModificationDate,
            permissions: permissions
        )
    }
}

enum SFTPTransferDirection: Equatable, Sendable {
    case upload
    case download

    var title: String { self == .upload ? "上傳" : "下載" }
    var symbol: String { self == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
}

enum SFTPTransferState: Equatable, Sendable {
    case waiting
    case transferring
    case completed
    case failed(String)

    var title: String {
        switch self {
        case .waiting: "等待中"
        case .transferring: "傳輸中"
        case .completed: "完成"
        case .failed(let message): "失敗：\(message)"
        }
    }
}

struct SFTPTransferItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let direction: SFTPTransferDirection
    let name: String
    var completedBytes: UInt64
    var totalBytes: UInt64?
    var state: SFTPTransferState

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}
