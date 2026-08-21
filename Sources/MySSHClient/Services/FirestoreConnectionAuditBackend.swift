import Foundation

enum FirestoreConnectionAuditBackendError: LocalizedError, Equatable {
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
        case .invalidRecord: "加密連線紀錄格式不正確。"
        case .invalidResponse: "雲端服務回傳的加密連線紀錄格式不正確。"
        case .responseTooLarge: "雲端連線紀錄超過安全大小限制。"
        case .permissionDenied: "雲端存取規則拒絕連線紀錄操作。"
        case .authenticationExpired: "Google 登入狀態已失效，請重新登入。"
        case .documentAlreadyExists: "這筆連線紀錄已存在。"
        case .serverFailure(let status): "雲端連線紀錄服務暫時無法完成同步（HTTP \(status)）。"
        case .tooManyPages: "雲端連線紀錄量超過安全上限。"
        }
    }
}

struct FirestoreConnectionAuditSnapshot: Sendable {
    let records: [EncryptedSyncRecord]
    let serverDate: Date?
}

struct FirestoreConnectionAuditBackend: Sendable {
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

    func fetchSnapshot(ownerUID: String, idToken: String) async throws -> FirestoreConnectionAuditSnapshot {
        var records: [EncryptedSyncRecord] = []
        var serverDate: Date?
        var pageToken: String?
        for _ in 0..<Self.maximumPageCount {
            let request = try listRequest(ownerUID: ownerUID, idToken: idToken, pageToken: pageToken)
            let (data, response) = try await session.data(for: request)
            guard data.count <= Self.maximumResponseSize else {
                throw FirestoreConnectionAuditBackendError.responseTooLarge
            }
            guard let response = response as? HTTPURLResponse else {
                throw FirestoreConnectionAuditBackendError.invalidResponse
            }
            guard response.statusCode == 200 else { throw mapStatus(response.statusCode) }
            let page = try decodePage(data)
            records.append(contentsOf: page.records)
            if serverDate == nil {
                serverDate = Self.parseHTTPDate(response.value(forHTTPHeaderField: "Date"))
            }
            pageToken = page.nextPageToken
            if pageToken == nil {
                return FirestoreConnectionAuditSnapshot(records: records, serverDate: serverDate)
            }
        }
        throw FirestoreConnectionAuditBackendError.tooManyPages
    }

    @discardableResult
    func create(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        idToken: String
    ) async throws -> EncryptedSyncRecord {
        let request = try createRequest(record, ownerUID: ownerUID, idToken: idToken)
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumCiphertextSize * 2 else {
            throw FirestoreConnectionAuditBackendError.responseTooLarge
        }
        guard let response = response as? HTTPURLResponse else {
            throw FirestoreConnectionAuditBackendError.invalidResponse
        }
        guard response.statusCode == 200 else { throw mapStatus(response.statusCode) }
        let saved = try decodeRecord(data)
        guard saved.id == record.id else {
            throw FirestoreConnectionAuditBackendError.invalidResponse
        }
        return saved
    }

    func delete(recordID: UUID, ownerUID: String, idToken: String) async throws {
        var request = URLRequest(url: try recordURL(ownerUID: ownerUID, recordID: recordID))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FirestoreConnectionAuditBackendError.invalidResponse
        }
        guard response.statusCode == 200 || response.statusCode == 404 else {
            throw mapStatus(response.statusCode)
        }
    }

    func createRequest(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        idToken: String
    ) throws -> URLRequest {
        try validate(record)
        guard !ownerUID.isEmpty, !idToken.isEmpty else {
            throw FirestoreConnectionAuditBackendError.invalidRecord
        }
        let body = ConnectionAuditFirestoreDocument(name: nil, fields: .init(record: record))
        var components = URLComponents(
            url: try recordURL(ownerUID: ownerUID, recordID: record.id),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "currentDocument.exists", value: "false")]
        guard let url = components?.url else {
            throw FirestoreConnectionAuditBackendError.invalidRecord
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func listRequest(ownerUID: String, idToken: String, pageToken: String?) throws -> URLRequest {
        guard !ownerUID.isEmpty, !idToken.isEmpty else {
            throw FirestoreConnectionAuditBackendError.invalidRecord
        }
        var components = URLComponents(
            url: try collectionURL(ownerUID: ownerUID),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "pageSize", value: String(Self.pageSize))]
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw FirestoreConnectionAuditBackendError.invalidRecord
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func decodeRecord(_ data: Data) throws -> EncryptedSyncRecord {
        guard data.count <= Self.maximumCiphertextSize * 2,
              let document = try? JSONDecoder().decode(ConnectionAuditFirestoreDocument.self, from: data) else {
            throw FirestoreConnectionAuditBackendError.invalidResponse
        }
        return try document.record()
    }

    func decodePage(_ data: Data) throws -> (records: [EncryptedSyncRecord], nextPageToken: String?) {
        guard data.count <= Self.maximumResponseSize,
              let response = try? JSONDecoder().decode(ConnectionAuditFirestoreListResponse.self, from: data) else {
            throw FirestoreConnectionAuditBackendError.invalidResponse
        }
        return (try response.documents.map { try $0.record() }, response.nextPageToken)
    }

    private func validate(_ record: EncryptedSyncRecord) throws {
        guard record.recordType == .connectionAudit,
              record.ciphertext.count > 0,
              record.ciphertext.count <= Self.maximumCiphertextSize,
              record.nonce.count == 12,
              record.authenticationTag.count == 16,
              record.keyVersion == VaultCryptoFormat.masterKeyVersion,
              record.formatVersion == VaultCryptoFormat.recordVersion,
              record.revision == 1,
              !record.deleted else {
            throw FirestoreConnectionAuditBackendError.invalidRecord
        }
    }

    private func collectionURL(ownerUID: String) throws -> URL {
        guard !ownerUID.isEmpty, !projectID.isEmpty else {
            throw FirestoreConnectionAuditBackendError.invalidRecord
        }
        return apiRoot
            .appending(path: "projects")
            .appending(path: projectID)
            .appending(path: "databases")
            .appending(path: "(default)")
            .appending(path: "documents")
            .appending(path: "users")
            .appending(path: ownerUID)
            .appending(path: "connectionLogs")
    }

    private func recordURL(ownerUID: String, recordID: UUID) throws -> URL {
        try collectionURL(ownerUID: ownerUID).appending(path: recordID.uuidString.lowercased())
    }

    private func mapStatus(_ status: Int) -> FirestoreConnectionAuditBackendError {
        switch status {
        case 401: .authenticationExpired
        case 403: .permissionDenied
        case 409, 412: .documentAlreadyExists
        default: .serverFailure(status)
        }
    }

    private static func parseHTTPDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

private struct ConnectionAuditFirestoreListResponse: Codable {
    let documents: [ConnectionAuditFirestoreDocument]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decodeIfPresent(
            [ConnectionAuditFirestoreDocument].self,
            forKey: .documents
        ) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct ConnectionAuditFirestoreDocument: Codable {
    struct Fields: Codable {
        let recordType: ConnectionAuditStringValue
        let ciphertext: ConnectionAuditBytesValue
        let nonce: ConnectionAuditBytesValue
        let authenticationTag: ConnectionAuditBytesValue
        let keyVersion: ConnectionAuditIntegerValue
        let formatVersion: ConnectionAuditIntegerValue

        init(record: EncryptedSyncRecord) {
            recordType = .init(stringValue: record.recordType.rawValue)
            ciphertext = .init(bytesValue: record.ciphertext.base64EncodedString())
            nonce = .init(bytesValue: record.nonce.base64EncodedString())
            authenticationTag = .init(bytesValue: record.authenticationTag.base64EncodedString())
            keyVersion = .init(integerValue: String(record.keyVersion))
            formatVersion = .init(integerValue: String(record.formatVersion))
        }
    }

    let name: String?
    let fields: Fields

    func record() throws -> EncryptedSyncRecord {
        guard let name,
              let id = UUID(uuidString: String(name.split(separator: "/").last ?? "")),
              fields.recordType.stringValue == SyncRecordType.connectionAudit.rawValue,
              let ciphertext = Data(base64Encoded: fields.ciphertext.bytesValue),
              let nonce = Data(base64Encoded: fields.nonce.bytesValue),
              let authenticationTag = Data(base64Encoded: fields.authenticationTag.bytesValue),
              let keyVersion = UInt32(fields.keyVersion.integerValue),
              let formatVersion = UInt32(fields.formatVersion.integerValue) else {
            throw FirestoreConnectionAuditBackendError.invalidResponse
        }
        let record = ConnectionAuditSyncCodec.cloudRecord(
            id: id,
            ciphertext: ciphertext,
            nonce: nonce,
            authenticationTag: authenticationTag,
            keyVersion: keyVersion,
            formatVersion: formatVersion
        )
        guard record.ciphertext.count > 0,
              record.ciphertext.count <= FirestoreConnectionAuditBackend.maximumCiphertextSize,
              record.nonce.count == 12,
              record.authenticationTag.count == 16,
              record.keyVersion == VaultCryptoFormat.masterKeyVersion,
              record.formatVersion == VaultCryptoFormat.recordVersion else {
            throw FirestoreConnectionAuditBackendError.invalidResponse
        }
        return record
    }
}

private struct ConnectionAuditStringValue: Codable { let stringValue: String }
private struct ConnectionAuditBytesValue: Codable { let bytesValue: String }
private struct ConnectionAuditIntegerValue: Codable { let integerValue: String }
