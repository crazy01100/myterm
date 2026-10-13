import Foundation

enum FirestoreBookmarkBackendError: Error { case invalidResponse, responseTooLarge, permissionDenied, authenticationExpired, documentAlreadyExists, serverFailure(Int), invalidRecord }
struct BookmarkCloudDocument {
    let record: EncryptedSyncRecord
    let updateTime: String
}
protocol BookmarkSyncBackend {
    func fetch(ownerUID: String, idToken: String) async throws -> [BookmarkCloudDocument]
    func write(_ record: EncryptedSyncRecord, expectedUpdateTime: String?, ownerUID: String, idToken: String) async throws
}
struct FirestoreBookmarkBackend: BookmarkSyncBackend {
    static let maximumCiphertextSize = BookmarkSyncPolicy.maximumCiphertext
    static let maximumResponseSize = 10 * 1024 * 1024
    static let maximumTotalSize = 32 * 1024 * 1024
    let projectID: String
    var session: URLSession = .shared
    var apiRoot = URL(string: "https://firestore.googleapis.com/v1")!

    private func prefix(_ uid: String) throws -> String {
        guard !projectID.isEmpty, !uid.isEmpty,
              [projectID, uid].allSatisfy({ !$0.contains("/") && $0 != "." && $0 != ".." }) else { throw BookmarkSyncError.invalidData }
        return "projects/\(projectID)/databases/(default)/documents/users/\(uid)/sftpBookmarks"
    }
    private func request(_ uid: String, token: String, id: UUID? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        guard !token.isEmpty else { throw BookmarkSyncError.invalidData }
        let path = try prefix(uid) + (id.map { "/" + $0.uuidString.lowercased() } ?? "")
        var url = apiRoot
        for component in path.split(separator: "/") { url.append(path: String(component)) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query
        guard let final = components.url else { throw BookmarkSyncError.invalidData }
        var request = URLRequest(url: final)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func receive(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw FirestoreBookmarkBackendError.invalidResponse }
        guard response.statusCode == 200 else {
            switch response.statusCode {
            case 401: throw FirestoreBookmarkBackendError.authenticationExpired
            case 403: throw FirestoreBookmarkBackendError.permissionDenied
            case 409, 412: throw FirestoreBookmarkBackendError.documentAlreadyExists
            default: throw FirestoreBookmarkBackendError.serverFailure(response.statusCode)
            }
        }
        guard response.expectedContentLength <= Int64(limit) else { throw FirestoreBookmarkBackendError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw FirestoreBookmarkBackendError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
    func fetch(ownerUID: String, idToken: String) async throws -> [BookmarkCloudDocument] {
        var result: [BookmarkCloudDocument] = [], token: String?
        var tokens = Set<String>(), ids = Set<UUID>(), total = 0
        for _ in 0..<120 {
            var query = [URLQueryItem(name: "pageSize", value: "50")]
            if let token { query.append(.init(name: "pageToken", value: token)) }
            let data = try await receive(request(ownerUID, token: idToken, query: query), limit: Self.maximumResponseSize)
            total += data.count
            guard total <= Self.maximumTotalSize else { throw BookmarkSyncError.capacity }
            let page = try JSONDecoder().decode(BookmarkFirestoreListResponse.self, from: data)
            guard page.documents.count <= 50 else { throw BookmarkSyncError.capacity }
            for document in page.documents {
                let record = try document.record()
                guard document.name == (try prefix(ownerUID)) + "/" + record.id.uuidString.lowercased(),
                      let update = document.updateTime, BookmarkTimestamp.parse(update) != nil,
                      ids.insert(record.id).inserted else { throw BookmarkSyncError.invalidData }
                result.append(.init(record: record, updateTime: update))
            }
            guard result.count <= BookmarkSyncPolicy.maximumEntries else { throw BookmarkSyncError.capacity }
            token = page.nextPageToken
            if token == nil || token == "" { return result }
            guard tokens.insert(token!).inserted else { throw BookmarkSyncError.invalidData }
        }
        throw BookmarkSyncError.capacity
    }
    func write(_ record: EncryptedSyncRecord, expectedUpdateTime: String?, ownerUID: String, idToken: String) async throws {
        guard record.recordType == .sftpBookmark, record.revision > 0,
              record.revision < UInt64(Int64.max), record.ciphertext.count <= Self.maximumCiphertextSize,
              record.deleted == record.ciphertext.isEmpty else { throw BookmarkSyncError.invalidData }
        let precondition: URLQueryItem
        if let expectedUpdateTime {
            guard BookmarkTimestamp.parse(expectedUpdateTime) != nil, record.revision > 1 else { throw BookmarkSyncError.invalidData }
            precondition = .init(name: "currentDocument.updateTime", value: expectedUpdateTime)
        } else {
            guard record.revision == 1 else { throw BookmarkSyncError.invalidData }
            precondition = .init(name: "currentDocument.exists", value: "false")
        }
        var request = try request(ownerUID, token: idToken, id: record.id, query: [precondition])
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(BookmarkFirestoreDocument(name: nil, fields: .init(record: record)))
        let data = try await receive(request, limit: Self.maximumCiphertextSize * 2)
        let document = try JSONDecoder().decode(BookmarkFirestoreDocument.self, from: data)
        let saved = try document.record()
        guard document.name == (try prefix(ownerUID)) + "/" + record.id.uuidString.lowercased(),
              saved == record else { throw BookmarkSyncError.invalidData }
    }
}

private struct BookmarkFirestoreListResponse: Codable {
    let documents: [BookmarkFirestoreDocument]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decodeIfPresent([BookmarkFirestoreDocument].self, forKey: .documents) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct BookmarkFirestoreDocument: Codable {
    struct Fields: Codable {
        let recordType: BookmarkStringValue
        let ciphertext: BookmarkBytesValue
        let nonce: BookmarkBytesValue
        let authenticationTag: BookmarkBytesValue
        let keyVersion: BookmarkIntegerValue
        let formatVersion: BookmarkIntegerValue
        let revision: BookmarkIntegerValue
        let modifiedAt: BookmarkTimestampValue
        let modifiedByDeviceID: BookmarkStringValue
        let deleted: BookmarkBooleanValue

        init(record: EncryptedSyncRecord) {
            recordType = .init(stringValue: record.recordType.rawValue)
            ciphertext = .init(bytesValue: record.ciphertext.base64EncodedString())
            nonce = .init(bytesValue: record.nonce.base64EncodedString())
            authenticationTag = .init(bytesValue: record.authenticationTag.base64EncodedString())
            keyVersion = .init(integerValue: String(record.keyVersion))
            formatVersion = .init(integerValue: String(record.formatVersion))
            revision = .init(integerValue: String(record.revision))
            modifiedAt = .init(timestampValue: BookmarkTimestamp.format(record.modifiedAt))
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
              let modifiedAt = BookmarkTimestamp.parse(fields.modifiedAt.timestampValue),
              let modifiedByDeviceID = UUID(uuidString: fields.modifiedByDeviceID.stringValue) else {
            throw FirestoreBookmarkBackendError.invalidResponse
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
        guard record.recordType == .sftpBookmark,
              record.ciphertext.count <= FirestoreBookmarkBackend.maximumCiphertextSize,
              record.nonce.count == 12,
              record.authenticationTag.count == 16,
              record.keyVersion == VaultCryptoFormat.masterKeyVersion,
              record.formatVersion == VaultCryptoFormat.recordVersion,
              record.revision > 0, record.revision < UInt64(Int64.max),
              record.deleted == record.ciphertext.isEmpty else {
            throw FirestoreBookmarkBackendError.invalidResponse
        }
        return record
    }
}

private struct BookmarkStringValue: Codable { let stringValue: String }
private struct BookmarkBytesValue: Codable { let bytesValue: String }
private struct BookmarkIntegerValue: Codable { let integerValue: String }
private struct BookmarkTimestampValue: Codable { let timestampValue: String }
private struct BookmarkBooleanValue: Codable { let booleanValue: Bool }

private enum BookmarkTimestamp {
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
