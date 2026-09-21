import Foundation

enum FirestoreSnippetBackendError: Error { case invalidResponse, responseTooLarge, permissionDenied, authenticationExpired, documentAlreadyExists, serverFailure(Int), invalidRecord }
struct SnippetCloudDocument {
    let record: EncryptedSyncRecord
    let updateTime: String
}
protocol SnippetSyncBackend {
    func fetch(ownerUID: String, idToken: String) async throws -> [SnippetCloudDocument]
    func write(_ record: EncryptedSyncRecord, expectedUpdateTime: String?, ownerUID: String, idToken: String) async throws
}
struct FirestoreSnippetBackend: SnippetSyncBackend {
    static let maximumCiphertextSize = SnippetSyncPolicy.maximumCiphertext
    static let maximumResponseSize = 10 * 1024 * 1024
    static let maximumTotalSize = 32 * 1024 * 1024
    let projectID: String
    var session: URLSession = .shared
    var apiRoot = URL(string: "https://firestore.googleapis.com/v1")!

    private func prefix(_ uid: String) throws -> String {
        guard !projectID.isEmpty, !uid.isEmpty,
              [projectID, uid].allSatisfy({ !$0.contains("/") && $0 != "." && $0 != ".." }) else { throw SnippetSyncError.invalidData }
        return "projects/\(projectID)/databases/(default)/documents/users/\(uid)/commandSnippets"
    }
    private func request(_ uid: String, token: String, id: UUID? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        guard !token.isEmpty else { throw SnippetSyncError.invalidData }
        let path = try prefix(uid) + (id.map { "/" + $0.uuidString.lowercased() } ?? "")
        var url = apiRoot
        for component in path.split(separator: "/") { url.append(path: String(component)) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query
        guard let final = components.url else { throw SnippetSyncError.invalidData }
        var request = URLRequest(url: final)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func receive(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw FirestoreSnippetBackendError.invalidResponse }
        guard response.statusCode == 200 else {
            switch response.statusCode {
            case 401: throw FirestoreSnippetBackendError.authenticationExpired
            case 403: throw FirestoreSnippetBackendError.permissionDenied
            case 409, 412: throw FirestoreSnippetBackendError.documentAlreadyExists
            default: throw FirestoreSnippetBackendError.serverFailure(response.statusCode)
            }
        }
        guard response.expectedContentLength <= Int64(limit) else { throw FirestoreSnippetBackendError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw FirestoreSnippetBackendError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
    func fetch(ownerUID: String, idToken: String) async throws -> [SnippetCloudDocument] {
        var result: [SnippetCloudDocument] = [], token: String?
        var tokens = Set<String>(), ids = Set<UUID>(), total = 0
        for _ in 0..<120 {
            var query = [URLQueryItem(name: "pageSize", value: "50")]
            if let token { query.append(.init(name: "pageToken", value: token)) }
            let data = try await receive(request(ownerUID, token: idToken, query: query), limit: Self.maximumResponseSize)
            total += data.count
            guard total <= Self.maximumTotalSize else { throw SnippetSyncError.capacity }
            let page = try JSONDecoder().decode(SnippetFirestoreListResponse.self, from: data)
            guard page.documents.count <= 50 else { throw SnippetSyncError.capacity }
            for document in page.documents {
                let record = try document.record()
                guard document.name == (try prefix(ownerUID)) + "/" + record.id.uuidString.lowercased(),
                      let update = document.updateTime, SnippetTimestamp.parse(update) != nil,
                      ids.insert(record.id).inserted else { throw SnippetSyncError.invalidData }
                result.append(.init(record: record, updateTime: update))
            }
            guard result.count <= SnippetSyncPolicy.maximumEntries else { throw SnippetSyncError.capacity }
            token = page.nextPageToken
            if token == nil || token == "" { return result }
            guard tokens.insert(token!).inserted else { throw SnippetSyncError.invalidData }
        }
        throw SnippetSyncError.capacity
    }
    func write(_ record: EncryptedSyncRecord, expectedUpdateTime: String?, ownerUID: String, idToken: String) async throws {
        guard record.recordType == .commandSnippet, record.revision > 0,
              record.revision < UInt64(Int64.max), record.ciphertext.count <= Self.maximumCiphertextSize,
              record.deleted == record.ciphertext.isEmpty else { throw SnippetSyncError.invalidData }
        let precondition: URLQueryItem
        if let expectedUpdateTime {
            guard SnippetTimestamp.parse(expectedUpdateTime) != nil, record.revision > 1 else { throw SnippetSyncError.invalidData }
            precondition = .init(name: "currentDocument.updateTime", value: expectedUpdateTime)
        } else {
            guard record.revision == 1 else { throw SnippetSyncError.invalidData }
            precondition = .init(name: "currentDocument.exists", value: "false")
        }
        var request = try request(ownerUID, token: idToken, id: record.id, query: [precondition])
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(SnippetFirestoreDocument(name: nil, fields: .init(record: record)))
        let data = try await receive(request, limit: Self.maximumCiphertextSize * 2)
        let document = try JSONDecoder().decode(SnippetFirestoreDocument.self, from: data)
        let saved = try document.record()
        guard document.name == (try prefix(ownerUID)) + "/" + record.id.uuidString.lowercased(),
              saved == record else { throw SnippetSyncError.invalidData }
    }
}

private struct SnippetFirestoreListResponse: Codable {
    let documents: [SnippetFirestoreDocument]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decodeIfPresent([SnippetFirestoreDocument].self, forKey: .documents) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct SnippetFirestoreDocument: Codable {
    struct Fields: Codable {
        let recordType: SnippetStringValue
        let ciphertext: SnippetBytesValue
        let nonce: SnippetBytesValue
        let authenticationTag: SnippetBytesValue
        let keyVersion: SnippetIntegerValue
        let formatVersion: SnippetIntegerValue
        let revision: SnippetIntegerValue
        let modifiedAt: SnippetTimestampValue
        let modifiedByDeviceID: SnippetStringValue
        let deleted: SnippetBooleanValue

        init(record: EncryptedSyncRecord) {
            recordType = .init(stringValue: record.recordType.rawValue)
            ciphertext = .init(bytesValue: record.ciphertext.base64EncodedString())
            nonce = .init(bytesValue: record.nonce.base64EncodedString())
            authenticationTag = .init(bytesValue: record.authenticationTag.base64EncodedString())
            keyVersion = .init(integerValue: String(record.keyVersion))
            formatVersion = .init(integerValue: String(record.formatVersion))
            revision = .init(integerValue: String(record.revision))
            modifiedAt = .init(timestampValue: SnippetTimestamp.format(record.modifiedAt))
            modifiedByDeviceID = .init(stringValue: record.modifiedByDeviceID.uuidString.lowercased())
            deleted = .init(booleanValue: record.deleted)
        }
    }

    let name: String?
    let fields: Fields
    let createTime: String?
    let updateTime: String?

    init(name: String?, fields: Fields) {
        self.name = name
        self.fields = fields
        createTime = nil
        updateTime = nil
    }

    func record() throws -> EncryptedSyncRecord {
        guard let name,
              let id = UUID(uuidString: String(name.split(separator: "/").last ?? "")),
              let recordType = SyncRecordType(rawValue: fields.recordType.stringValue),
              let ciphertext = Data(base64Encoded: fields.ciphertext.bytesValue),
              let nonce = Data(base64Encoded: fields.nonce.bytesValue),
              let authenticationTag = Data(base64Encoded: fields.authenticationTag.bytesValue),
              let keyVersion = UInt32(fields.keyVersion.integerValue),
              let formatVersion = UInt32(fields.formatVersion.integerValue),
              let revision = UInt64(fields.revision.integerValue),
              let modifiedAt = SnippetTimestamp.parse(fields.modifiedAt.timestampValue),
              let modifiedByDeviceID = UUID(uuidString: fields.modifiedByDeviceID.stringValue) else {
            throw FirestoreSnippetBackendError.invalidResponse
        }
        let record = EncryptedSyncRecord(
            id: id,
            recordType: recordType,
            ciphertext: ciphertext,
            nonce: nonce,
            authenticationTag: authenticationTag,
            keyVersion: keyVersion,
            formatVersion: formatVersion,
            revision: revision,
            modifiedAt: modifiedAt,
            modifiedByDeviceID: modifiedByDeviceID,
            deleted: fields.deleted.booleanValue
        )
        guard record.recordType == .commandSnippet,
              record.ciphertext.count <= FirestoreSnippetBackend.maximumCiphertextSize,
              record.nonce.count == 12,
              record.authenticationTag.count == 16,
              record.keyVersion == VaultCryptoFormat.masterKeyVersion,
              record.formatVersion == VaultCryptoFormat.recordVersion,
              record.revision > 0, record.revision < UInt64(Int64.max),
              record.deleted == record.ciphertext.isEmpty else {
            throw FirestoreSnippetBackendError.invalidResponse
        }
        return record
    }
}

private struct SnippetStringValue: Codable { let stringValue: String }
private struct SnippetBytesValue: Codable { let bytesValue: String }
private struct SnippetIntegerValue: Codable { let integerValue: String }
private struct SnippetTimestampValue: Codable { let timestampValue: String }
private struct SnippetBooleanValue: Codable { let booleanValue: Bool }

private enum SnippetTimestamp {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
