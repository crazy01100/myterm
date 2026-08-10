import CryptoKit
import Foundation

struct KnownHostRecord: Identifiable, Codable, Hashable {
    let id: String
    let marker: String?
    let hostField: String
    let keyType: String
    let keyData: String
    let comment: String
    let rawLine: String

    var isHashed: Bool { hostField.hasPrefix("|1|") }

    var displayHost: String {
        if isHashed { return "雜湊主機 · \(id.prefix(6))" }
        return hostField.split(separator: ",", maxSplits: 1).first.map(String.init) ?? hostField
    }

    var fingerprint: String {
        guard let key = Data(base64Encoded: keyData) else { return "無法計算指紋" }
        let digest = Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }
}

struct ImportedKnownHostsDocument: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var sourcePath = "~/.ssh/known_hosts"
    var lastSyncedAt: Date
    var records: [KnownHostRecord]
}

enum KnownHostsParser {
    static func parse(_ contents: String) -> [KnownHostRecord] {
        var seen = Set<String>()
        var records: [KnownHostRecord] = []

        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)

            var index = 0
            let marker: String?
            if fields.first?.hasPrefix("@") == true {
                marker = fields[0]
                index = 1
            } else {
                marker = nil
            }
            guard fields.count >= index + 3 else { continue }

            let hostField = fields[index]
            let keyType = fields[index + 1]
            let keyData = fields[index + 2]
            guard !hostField.isEmpty, !keyType.isEmpty, Data(base64Encoded: keyData) != nil else { continue }

            let comment = fields.count > index + 3 ? fields[(index + 3)...].joined(separator: " ") : ""
            let id = SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(id).inserted else { continue }
            records.append(KnownHostRecord(
                id: id,
                marker: marker,
                hostField: hostField,
                keyType: keyType,
                keyData: keyData,
                comment: comment,
                rawLine: line
            ))
        }

        return records.sorted { $0.displayHost.localizedStandardCompare($1.displayHost) == .orderedAscending }
    }
}
