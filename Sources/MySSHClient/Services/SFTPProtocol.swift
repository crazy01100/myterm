import Foundation

enum SFTPProtocolError: LocalizedError, Equatable {
    case resourceLimit
    case malformedPacket
    case packetTooLarge(Int)
    case unsupportedVersion(UInt32)
    case unexpectedPacket(UInt8)
    case mismatchedRequest(expected: UInt32, actual: UInt32)
    case serverStatus(code: UInt32, message: String)
    case invalidString

    var errorDescription: String? {
        switch self {
        case .resourceLimit: "SFTP 目錄資料或遞迴深度超過安全上限，操作已停止。"
        case .malformedPacket: "SFTP 伺服器傳回了格式不正確的資料。"
        case .packetTooLarge(let size): "SFTP 封包超過安全上限（\(size) bytes）。"
        case .unsupportedVersion(let version): "伺服器使用不支援的 SFTP 版本 \(version)。"
        case .unexpectedPacket(let type): "SFTP 伺服器傳回非預期的封包（類型 \(type)）。"
        case .mismatchedRequest: "SFTP 回應與目前的要求不相符。"
        case .serverStatus(_, let message): message.isEmpty ? "SFTP 操作失敗。" : message
        case .invalidString: "SFTP 回應包含無法辨識的文字編碼。"
        }
    }
}

enum SFTPPacketType {
    static let initialize: UInt8 = 1
    static let version: UInt8 = 2
    static let close: UInt8 = 4
    static let open: UInt8 = 3
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let lstat: UInt8 = 7
    static let setstat: UInt8 = 9
    static let openDirectory: UInt8 = 11
    static let readDirectory: UInt8 = 12
    static let remove: UInt8 = 13
    static let makeDirectory: UInt8 = 14
    static let removeDirectory: UInt8 = 15
    static let realPath: UInt8 = 16
    static let stat: UInt8 = 17
    static let rename: UInt8 = 18
    static let status: UInt8 = 101
    static let handle: UInt8 = 102
    static let data: UInt8 = 103
    static let name: UInt8 = 104
    static let attributes: UInt8 = 105
}

enum SFTPStatusCode {
    static let ok: UInt32 = 0
    static let endOfFile: UInt32 = 1
}

struct SFTPPacketWriter {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt32) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    mutating func append(data value: Data) {
        append(UInt32(value.count))
        data.append(value)
    }

    mutating func append(string value: String) {
        append(data: Data(value.utf8))
    }

    mutating func appendEmptyAttributes() {
        append(UInt32(0))
    }

    mutating func appendPermissions(_ permissions: UInt32) {
        append(UInt32(0x0000_0004))
        append(permissions)
    }

    func framed() -> Data {
        var result = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(data)
        return result
    }
}

struct SFTPPacketReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remainingCount: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw SFTPProtocolError.malformedPacket }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readData() throws -> Data {
        let count = Int(try readUInt32())
        return Data(try readBytes(count: count))
    }

    mutating func readString() throws -> String {
        let bytes = try readData()
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw SFTPProtocolError.invalidString
        }
        return value
    }

    mutating func readAttributes() throws -> SFTPFileAttributes {
        let flags = try readUInt32()
        var result = SFTPFileAttributes()
        if flags & 0x0000_0001 != 0 { result.size = try readUInt64() }
        if flags & 0x0000_0002 != 0 {
            result.userID = try readUInt32()
            result.groupID = try readUInt32()
        }
        if flags & 0x0000_0004 != 0 { result.permissions = try readUInt32() }
        if flags & 0x0000_0008 != 0 {
            result.accessTime = Date(timeIntervalSince1970: TimeInterval(try readUInt32()))
            result.modificationTime = Date(timeIntervalSince1970: TimeInterval(try readUInt32()))
        }
        if flags & 0x8000_0000 != 0 {
            let count = try readUInt32()
            guard count <= 4_096 else { throw SFTPProtocolError.malformedPacket }
            for _ in 0..<count {
                _ = try readData()
                _ = try readData()
            }
        }
        return result
    }

    private mutating func readBytes(count: Int) throws -> Data.SubSequence {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw SFTPProtocolError.malformedPacket
        }
        let range = offset..<(offset + count)
        offset += count
        return data[range]
    }
}

enum SFTPProtocolCodec {
    static let supportedVersion: UInt32 = 3
    static let maximumPacketSize = 16 * 1_024 * 1_024

    static func initializationPacket() -> Data {
        var writer = SFTPPacketWriter()
        writer.append(SFTPPacketType.initialize)
        writer.append(supportedVersion)
        return writer.framed()
    }

    static func requestPacket(type: UInt8, requestID: UInt32, body: (inout SFTPPacketWriter) -> Void) -> Data {
        var writer = SFTPPacketWriter()
        writer.append(type)
        writer.append(requestID)
        body(&writer)
        return writer.framed()
    }

    static func parseVersion(_ packet: Data) throws {
        var reader = SFTPPacketReader(packet)
        guard try reader.readUInt8() == SFTPPacketType.version else {
            throw SFTPProtocolError.unexpectedPacket(packet.first ?? 0)
        }
        let version = try reader.readUInt32()
        guard version == supportedVersion else { throw SFTPProtocolError.unsupportedVersion(version) }
        // Remaining bytes are optional extension name/value pairs.
    }

    static func responseReader(_ packet: Data, expectedRequestID: UInt32) throws -> (UInt8, SFTPPacketReader) {
        var reader = SFTPPacketReader(packet)
        let type = try reader.readUInt8()
        let requestID = try reader.readUInt32()
        guard requestID == expectedRequestID else {
            throw SFTPProtocolError.mismatchedRequest(expected: expectedRequestID, actual: requestID)
        }
        return (type, reader)
    }

    static func parseStatus(_ reader: inout SFTPPacketReader, allowEndOfFile: Bool = false) throws -> Bool {
        let code = try reader.readUInt32()
        let message = reader.remainingCount > 0 ? (try? reader.readString()) ?? "" : ""
        if code == SFTPStatusCode.ok { return true }
        if allowEndOfFile, code == SFTPStatusCode.endOfFile { return false }
        throw SFTPProtocolError.serverStatus(code: code, message: localizedStatus(code: code, serverMessage: message))
    }

    static func parseNameEntries(_ reader: inout SFTPPacketReader) throws -> [SFTPDirectoryEntry] {
        let count = try reader.readUInt32()
        guard count <= 100_000 else { throw SFTPProtocolError.malformedPacket }
        var result: [SFTPDirectoryEntry] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            result.append(SFTPDirectoryEntry(
                name: try reader.readString(),
                longName: try reader.readString(),
                attributes: try reader.readAttributes()
            ))
        }
        return result
    }

    static func parseData(_ reader: inout SFTPPacketReader) throws -> Data {
        try reader.readData()
    }

    private static func localizedStatus(code: UInt32, serverMessage: String) -> String {
        let message: String
        switch code {
        case 1: message = "已到達目錄結尾。"
        case 2: message = "找不到遠端檔案或目錄。"
        case 3: message = "沒有權限執行這項 SFTP 操作。"
        case 4: message = "遠端伺服器無法完成這項 SFTP 操作。"
        case 5: message = "SFTP 回應包含無效訊息。"
        case 6: message = "SFTP 連線已中斷。"
        case 7: message = "SFTP 連線已關閉。"
        case 8: message = "遠端伺服器不支援這項 SFTP 操作。"
        default: message = "SFTP 操作失敗（狀態碼 \(code)）。"
        }
        return serverMessage.isEmpty ? message : "\(message) 伺服器訊息：\(serverMessage)"
    }
}
