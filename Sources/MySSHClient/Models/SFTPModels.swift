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

    var permissionTypeCharacter: Character {
        switch self {
        case .directory: "d"
        case .regularFile: "-"
        case .symbolicLink: "l"
        case .other: "?"
        }
    }
}

struct SFTPPermissionMode: Equatable, Sendable {
    enum AccessClass: Int, CaseIterable, Identifiable, Sendable {
        case owner = 6
        case group = 3
        case others = 0

        var id: Self { self }

        var title: String {
            switch self {
            case .owner: "擁有者"
            case .group: "群組"
            case .others: "其他人"
            }
        }
    }

    enum AccessRight: UInt32, CaseIterable, Identifiable, Sendable {
        case read = 0o4
        case write = 0o2
        case execute = 0o1

        var id: Self { self }

        var title: String {
            switch self {
            case .read: "讀取"
            case .write: "寫入"
            case .execute: "執行"
            }
        }
    }

    enum SpecialRight: UInt32, CaseIterable, Identifiable, Sendable {
        case setUserID = 0o4000
        case setGroupID = 0o2000
        case sticky = 0o1000

        var id: Self { self }

        var title: String {
            switch self {
            case .setUserID: "setuid"
            case .setGroupID: "setgid"
            case .sticky: "sticky"
            }
        }
    }

    private(set) var rawValue: UInt32

    init(_ permissions: UInt32) {
        rawValue = permissions & 0o7777
    }

    init?(octalString: String) {
        let trimmed = octalString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...4).contains(trimmed.count),
              trimmed.allSatisfy({ ("0"..."7").contains(String($0)) }),
              let value = UInt32(trimmed, radix: 8), value <= 0o7777 else {
            return nil
        }
        self.init(value)
    }

    var octalString: String {
        String(rawValue, radix: 8)
    }

    var paddedOctalString: String {
        String(format: "%04o", Int(rawValue))
    }

    func contains(_ right: AccessRight, for accessClass: AccessClass) -> Bool {
        rawValue & bit(for: right, accessClass: accessClass) != 0
    }

    mutating func set(_ right: AccessRight, for accessClass: AccessClass, enabled: Bool) {
        let targetBit = bit(for: right, accessClass: accessClass)
        if enabled {
            rawValue |= targetBit
        } else {
            rawValue &= ~targetBit
        }
    }

    func contains(_ specialRight: SpecialRight) -> Bool {
        rawValue & specialRight.rawValue != 0
    }

    mutating func set(_ specialRight: SpecialRight, enabled: Bool) {
        if enabled {
            rawValue |= specialRight.rawValue
        } else {
            rawValue &= ~specialRight.rawValue
        }
    }

    func symbolicString(kind: SFTPFileKind) -> String {
        var result = String(kind.permissionTypeCharacter)
        for accessClass in AccessClass.allCases {
            result.append(contains(.read, for: accessClass) ? "r" : "-")
            result.append(contains(.write, for: accessClass) ? "w" : "-")
            result.append(executeCharacter(for: accessClass))
        }
        return result
    }

    private func bit(for right: AccessRight, accessClass: AccessClass) -> UInt32 {
        right.rawValue << UInt32(accessClass.rawValue)
    }

    private func executeCharacter(for accessClass: AccessClass) -> Character {
        let isExecutable = contains(.execute, for: accessClass)
        switch accessClass {
        case .owner where contains(.setUserID):
            return isExecutable ? "s" : "S"
        case .group where contains(.setGroupID):
            return isExecutable ? "s" : "S"
        case .others where contains(.sticky):
            return isExecutable ? "t" : "T"
        default:
            return isExecutable ? "x" : "-"
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
    var kind: SFTPFileKind {
        if isSymbolicLink { return .symbolicLink }
        return isDirectory ? .directory : .regularFile
    }
    var kindTitle: String { kind.title }

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
    case cancelling
    case cancelled
    case completed
    case failed(String)
    case needsAttention(String)

    var isFinished: Bool {
        switch self {
        case .waiting, .transferring, .cancelling: false
        case .cancelled, .completed, .failed, .needsAttention: true
        }
    }

    var title: String {
        switch self {
        case .waiting: "等待中"
        case .transferring: "傳輸中"
        case .cancelling: "正在取消"
        case .cancelled: "已取消"
        case .completed: "完成"
        case .failed(let message): "失敗：\(message)"
        case .needsAttention(let message): "待確認：\(message)"
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
    var targetDescription = ""
    var sourcePath = ""
    var destinationPath = ""
    var timing = SFTPTransferTiming()

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    // Completion means the final file operation succeeded, not just that all bytes were sent.
    var progressPercentage: Double? {
        guard totalBytes != nil else { return nil }
        if state == .completed { return 100 }
        guard let fractionCompleted else { return nil }
        return min(99.9, (fractionCompleted * 1_000).rounded() / 10)
    }

    var progressDescription: String {
        guard let totalBytes else { return "總大小未知" }
        if state == .transferring, completedBytes >= totalBytes { return "正在完成" }
        guard let progressPercentage else { return "處理中" }
        return String(format: "%.1f%%", progressPercentage)
    }
}

struct SFTPTransferTiming: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let time: TimeInterval
        let bytes: UInt64
    }
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var startUptime: TimeInterval?
    private(set) var endUptime: TimeInterval?
    private(set) var samples: [Sample] = []

    mutating func start(now: TimeInterval, date: Date) {
        guard startUptime == nil else { return }
        startUptime = now; startedAt = date
        samples = [Sample(time: now, bytes: 0)]
    }

    mutating func record(bytes: UInt64, now: TimeInterval) {
        guard endUptime == nil, let last = samples.last,
              now >= last.time, bytes >= last.bytes else { return }
        // At most ten samples per second, retaining a short moving window.
        guard now - last.time >= 0.1 else { return }
        samples.append(Sample(time: now, bytes: bytes))
        while samples.count > 2, samples[1].time < now - 3 { samples.removeFirst() }
    }

    mutating func finish(now: TimeInterval, date: Date) {
        guard endUptime == nil else { return }
        endUptime = now; endedAt = date
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let startUptime else { return 0 }
        return max(0, (endUptime ?? now) - startUptime)
    }

    func speed(at now: TimeInterval) -> Double? {
        guard endUptime == nil, let first = samples.first, let last = samples.last else { return nil }
        if now - last.time > 2 { return 0 }
        let duration = last.time - first.time
        guard duration >= 0.25 else { return nil }
        return Double(last.bytes - first.bytes) / duration
    }

    func remaining(bytes: UInt64, total: UInt64?, now: TimeInterval) -> TimeInterval? {
        guard let total, total > bytes, let rate = speed(at: now), rate > 0 else { return nil }
        let result = Double(total - bytes) / rate
        return result.isFinite ? result : nil
    }
}
