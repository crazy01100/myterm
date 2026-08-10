import Foundation

enum FirestoreMetadataBackendError: LocalizedError, Equatable {
    case invalidRecord
    case invalidResponse
    case responseTooLarge
    case permissionDenied
    case authenticationExpired
    case documentAlreadyExists
    case serverFailure(Int)
    case tooManyPages

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "加密同步紀錄格式不正確。"
        case .invalidResponse: "雲端同步服務回傳的加密紀錄格式不正確。"
        case .responseTooLarge: "雲端同步服務回傳的資料超過安全大小限制。"
        case .permissionDenied: "雲端存取規則拒絕讀寫同步紀錄。"
        case .authenticationExpired: "Google 登入狀態已失效，請重新登入。"
        case .documentAlreadyExists: "雲端同步紀錄已由另一個操作建立，已停止以避免覆蓋。"
        case .serverFailure(let status): "雲端同步服務暫時無法完成同步（HTTP \(status)）。"
        case .tooManyPages: "雲端同步資料量超過安全上限。"
        }
    }
}

struct FirestoreMetadataBackend: Sendable {
    static let maximumCiphertextSize = 64 * 1024
    static let maximumResponseSize = 10 * 1024 * 1024
    static let pageSize = 100
    static let maximumPageCount = 100

    let projectID: String
    let session: URLSession
    let apiRoot: URL

    init(
        projectID: String,
        session: URLSession = .shared,
        apiRoot: URL = URL(string: "https://firestore.googleapis.com/v1")!
    ) {
        self.projectID = projectID
        self.session = session
        self.apiRoot = apiRoot
    }

    @discardableResult
    func upsert(_ record: EncryptedSyncRecord, ownerUID: String, idToken: String) async throws -> EncryptedSyncRecord {
        let request = try upsertRequest(record, ownerUID: ownerUID, idToken: idToken)
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumCiphertextSize * 2 else {
            throw FirestoreMetadataBackendError.responseTooLarge
        }
        guard let response = response as? HTTPURLResponse else {
            throw FirestoreMetadataBackendError.invalidResponse
        }
        guard response.statusCode == 200 else { throw mapStatus(response.statusCode) }
        let saved = try decodeRecord(data)
        guard saved.id == record.id, saved.recordType == record.recordType else {
            throw FirestoreMetadataBackendError.invalidResponse
        }
        return saved
    }

    @discardableResult
    func create(_ record: EncryptedSyncRecord, ownerUID: String, idToken: String) async throws -> EncryptedSyncRecord {
        let request = try createRequest(record, ownerUID: ownerUID, idToken: idToken)
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumCiphertextSize * 2 else {
            throw FirestoreMetadataBackendError.responseTooLarge
        }
        guard let response = response as? HTTPURLResponse else {
            throw FirestoreMetadataBackendError.invalidResponse
        }
        guard response.statusCode == 200 else { throw mapStatus(response.statusCode) }
        let saved = try decodeRecord(data)
        guard saved.id == record.id, saved.recordType == record.recordType else {
            throw FirestoreMetadataBackendError.invalidResponse
        }
        return saved
    }

    func fetchAll(ownerUID: String, idToken: String) async throws -> [EncryptedSyncRecord] {
        try await fetchSnapshot(ownerUID: ownerUID, idToken: idToken).records.filter {
            $0.recordType == .host || $0.recordType == .group
        }
    }

    func fetchSnapshot(ownerUID: String, idToken: String) async throws -> FirestoreMetadataSnapshot {
        var records: [EncryptedSyncRecord] = []
        var updateTimes: [UUID: Date] = [:]
        var serverDate: Date?
        var pageToken: String?
        for _ in 0..<Self.maximumPageCount {
            let request = try listRequest(ownerUID: ownerUID, idToken: idToken, pageToken: pageToken)
            let (data, response) = try await session.data(for: request)
            guard data.count <= Self.maximumResponseSize else {
                throw FirestoreMetadataBackendError.responseTooLarge
            }
            guard let response = response as? HTTPURLResponse else {
                throw FirestoreMetadataBackendError.invalidResponse
            }
            guard response.statusCode == 200 else { throw mapStatus(response.statusCode) }
            let page = try decodePageSnapshot(data)
            records.append(contentsOf: page.records)
            updateTimes.merge(page.updateTimes) { _, new in new }
            if serverDate == nil {
                serverDate = Self.parseHTTPDate(response.value(forHTTPHeaderField: "Date"))
            }
            pageToken = page.nextPageToken
            if pageToken == nil {
                return FirestoreMetadataSnapshot(
                    records: records,
                    updateTimes: updateTimes,
                    serverDate: serverDate
                )
            }
        }
        throw FirestoreMetadataBackendError.tooManyPages
    }

    func upsertRequest(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        idToken: String
    ) throws -> URLRequest {
        try validate(record)
        guard !ownerUID.isEmpty, !idToken.isEmpty else {
            throw FirestoreMetadataBackendError.invalidRecord
        }
        let body = MetadataFirestoreDocument(
            name: nil,
            fields: .init(record: record)
        )
        var request = URLRequest(url: try recordURL(ownerUID: ownerUID, recordID: record.id))
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func createRequest(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        idToken: String
    ) throws -> URLRequest {
        var request = try upsertRequest(record, ownerUID: ownerUID, idToken: idToken)
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FirestoreMetadataBackendError.invalidRecord
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "currentDocument.exists", value: "false"))
        components.queryItems = queryItems
        guard let conditionalURL = components.url else {
            throw FirestoreMetadataBackendError.invalidRecord
        }
        request.url = conditionalURL
        return request
    }

    func listRequest(ownerUID: String, idToken: String, pageToken: String?) throws -> URLRequest {
        guard !ownerUID.isEmpty, !idToken.isEmpty else {
            throw FirestoreMetadataBackendError.invalidRecord
        }
        var components = URLComponents(url: try collectionURL(ownerUID: ownerUID), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "pageSize", value: String(Self.pageSize))]
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw FirestoreMetadataBackendError.invalidRecord }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func decodeRecord(_ data: Data) throws -> EncryptedSyncRecord {
        guard data.count <= Self.maximumCiphertextSize * 2,
              let document = try? JSONDecoder().decode(MetadataFirestoreDocument.self, from: data) else {
            throw FirestoreMetadataBackendError.invalidResponse
        }
        return try document.record()
    }

    func decodePage(_ data: Data) throws -> (records: [EncryptedSyncRecord], nextPageToken: String?) {
        let snapshot = try decodePageSnapshot(data)
        return (snapshot.records, snapshot.nextPageToken)
    }

    func decodePageSnapshot(
        _ data: Data
    ) throws -> (records: [EncryptedSyncRecord], updateTimes: [UUID: Date], nextPageToken: String?) {
        guard data.count <= Self.maximumResponseSize,
              let response = try? JSONDecoder().decode(MetadataFirestoreListResponse.self, from: data) else {
            throw FirestoreMetadataBackendError.invalidResponse
        }
        let decoded = try response.documents.map { document -> (EncryptedSyncRecord, Date?) in
            (try document.record(), document.updateTime.flatMap(MetadataTimestamp.parse))
        }
        let updateTimes = Dictionary(uniqueKeysWithValues: decoded.compactMap { record, date in
            date.map { (record.id, $0) }
        })
        return (decoded.map(\.0), updateTimes, response.nextPageToken)
    }

    private static func parseHTTPDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }

    private func validate(_ record: EncryptedSyncRecord) throws {
        guard record.recordType == .host || record.recordType == .group || record.recordType == .password,
              record.ciphertext.count <= Self.maximumCiphertextSize,
              record.nonce.count == 12,
              record.authenticationTag.count == 16,
              record.keyVersion == VaultCryptoFormat.masterKeyVersion,
              record.formatVersion == VaultCryptoFormat.recordVersion,
              record.revision > 0,
              record.deleted == record.ciphertext.isEmpty else {
            throw FirestoreMetadataBackendError.invalidRecord
        }
    }

    private func collectionURL(ownerUID: String) throws -> URL {
        guard !ownerUID.isEmpty, !projectID.isEmpty else {
            throw FirestoreMetadataBackendError.invalidRecord
        }
        return apiRoot
            .appending(path: "projects")
            .appending(path: projectID)
            .appending(path: "databases")
            .appending(path: "(default)")
            .appending(path: "documents")
            .appending(path: "users")
            .appending(path: ownerUID)
            .appending(path: "vault")
    }

    private func recordURL(ownerUID: String, recordID: UUID) throws -> URL {
        try collectionURL(ownerUID: ownerUID).appending(path: recordID.uuidString.lowercased())
    }

    private func mapStatus(_ status: Int) -> FirestoreMetadataBackendError {
        switch status {
        case 401: .authenticationExpired
        case 403: .permissionDenied
        case 409, 412: .documentAlreadyExists
        default: .serverFailure(status)
        }
    }
}

private struct MetadataFirestoreListResponse: Codable {
    let documents: [MetadataFirestoreDocument]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decodeIfPresent([MetadataFirestoreDocument].self, forKey: .documents) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct MetadataFirestoreDocument: Codable {
    struct Fields: Codable {
        let recordType: MetadataStringValue
        let ciphertext: MetadataBytesValue
        let nonce: MetadataBytesValue
        let authenticationTag: MetadataBytesValue
        let keyVersion: MetadataIntegerValue
        let formatVersion: MetadataIntegerValue
        let revision: MetadataIntegerValue
        let modifiedAt: MetadataTimestampValue
        let modifiedByDeviceID: MetadataStringValue
        let deleted: MetadataBooleanValue

        init(record: EncryptedSyncRecord) {
            recordType = .init(stringValue: record.recordType.rawValue)
            ciphertext = .init(bytesValue: record.ciphertext.base64EncodedString())
            nonce = .init(bytesValue: record.nonce.base64EncodedString())
            authenticationTag = .init(bytesValue: record.authenticationTag.base64EncodedString())
            keyVersion = .init(integerValue: String(record.keyVersion))
            formatVersion = .init(integerValue: String(record.formatVersion))
            revision = .init(integerValue: String(record.revision))
            modifiedAt = .init(timestampValue: MetadataTimestamp.format(record.modifiedAt))
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
              let modifiedAt = MetadataTimestamp.parse(fields.modifiedAt.timestampValue),
              let modifiedByDeviceID = UUID(uuidString: fields.modifiedByDeviceID.stringValue) else {
            throw FirestoreMetadataBackendError.invalidResponse
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
        guard record.recordType == .host || record.recordType == .group || record.recordType == .password,
              record.ciphertext.count <= FirestoreMetadataBackend.maximumCiphertextSize,
              record.nonce.count == 12,
              record.authenticationTag.count == 16,
              record.keyVersion == VaultCryptoFormat.masterKeyVersion,
              record.formatVersion == VaultCryptoFormat.recordVersion,
              record.revision > 0,
              record.deleted == record.ciphertext.isEmpty else {
            throw FirestoreMetadataBackendError.invalidResponse
        }
        return record
    }
}

private struct MetadataStringValue: Codable { let stringValue: String }
private struct MetadataBytesValue: Codable { let bytesValue: String }
private struct MetadataIntegerValue: Codable { let integerValue: String }
private struct MetadataTimestampValue: Codable { let timestampValue: String }
private struct MetadataBooleanValue: Codable { let booleanValue: Bool }

private enum MetadataTimestamp {
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
