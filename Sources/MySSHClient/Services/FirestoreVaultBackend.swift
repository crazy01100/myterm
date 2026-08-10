import Foundation

enum FirestoreVaultBackendError: LocalizedError, Equatable {
    case invalidRequest
    case payloadTooLarge
    case invalidResponse
    case permissionDenied
    case authenticationExpired
    case serverFailure(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "無法建立雲端加密封套請求。"
        case .payloadTooLarge: "加密封套超過允許的 64 KiB。"
        case .invalidResponse: "雲端同步服務回傳的加密封套格式不正確。"
        case .permissionDenied: "雲端存取規則拒絕讀寫加密封套。"
        case .authenticationExpired: "Google 登入狀態已失效，請重新登入。"
        case .serverFailure(let status): "雲端同步服務暫時無法完成操作（HTTP \(status)）。"
        }
    }
}

struct FirestoreVaultBackend: Sendable {
    static let maximumPayloadSize = 64 * 1024

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

    func fetchEnvelope(ownerUID: String, idToken: String) async throws -> LocalVaultEnvelopeDocument? {
        let request = try fetchRequest(ownerUID: ownerUID, idToken: idToken)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FirestoreVaultBackendError.invalidResponse
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw mapStatus(response.statusCode) }
        return try decodeDocument(data, expectedOwnerUID: ownerUID)
    }

    func upsertEnvelope(
        _ document: LocalVaultEnvelopeDocument,
        ownerUID: String,
        idToken: String
    ) async throws {
        let request = try upsertRequest(document, ownerUID: ownerUID, idToken: idToken)
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FirestoreVaultBackendError.invalidResponse
        }
        guard response.statusCode == 200 else { throw mapStatus(response.statusCode) }
    }

    func fetchRequest(ownerUID: String, idToken: String) throws -> URLRequest {
        var request = URLRequest(url: try documentURL(ownerUID: ownerUID))
        request.httpMethod = "GET"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func upsertRequest(
        _ document: LocalVaultEnvelopeDocument,
        ownerUID: String,
        idToken: String
    ) throws -> URLRequest {
        guard document.ownerUID == ownerUID,
              document.schemaVersion == LocalVaultEnvelopeDocument.currentSchemaVersion else {
            throw VaultSetupError.ownerMismatch
        }
        let payload = try JSONEncoder.firestoreVaultPayload.encode(document)
        guard payload.count <= Self.maximumPayloadSize else {
            throw FirestoreVaultBackendError.payloadTooLarge
        }
        let body = FirestoreVaultDocument(
            fields: .init(
                documentType: .init(stringValue: "vaultKeyEnvelope"),
                schemaVersion: .init(integerValue: String(document.schemaVersion)),
                payload: .init(bytesValue: payload.base64EncodedString())
            )
        )
        var request = URLRequest(url: try documentURL(ownerUID: ownerUID))
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func decodeDocument(_ data: Data, expectedOwnerUID: String) throws -> LocalVaultEnvelopeDocument {
        guard data.count <= Self.maximumPayloadSize * 2,
              let response = try? JSONDecoder().decode(FirestoreVaultDocument.self, from: data),
              response.fields.documentType.stringValue == "vaultKeyEnvelope",
              response.fields.schemaVersion.integerValue == String(LocalVaultEnvelopeDocument.currentSchemaVersion),
              let payload = Data(base64Encoded: response.fields.payload.bytesValue),
              payload.count <= Self.maximumPayloadSize,
              let document = try? JSONDecoder.firestoreVaultPayload.decode(
                LocalVaultEnvelopeDocument.self,
                from: payload
              ),
              document.ownerUID == expectedOwnerUID,
              document.schemaVersion == LocalVaultEnvelopeDocument.currentSchemaVersion else {
            throw FirestoreVaultBackendError.invalidResponse
        }
        return document
    }

    private func documentURL(ownerUID: String) throws -> URL {
        guard !ownerUID.isEmpty, !projectID.isEmpty else {
            throw FirestoreVaultBackendError.invalidRequest
        }
        return apiRoot
            .appending(path: "projects")
            .appending(path: projectID)
            .appending(path: "databases")
            .appending(path: "(default)")
            .appending(path: "documents")
            .appending(path: "users")
            .appending(path: ownerUID)
            .appending(path: "vaultKeys")
            .appending(path: "current")
    }

    private func mapStatus(_ status: Int) -> FirestoreVaultBackendError {
        switch status {
        case 401: .authenticationExpired
        case 403: .permissionDenied
        default: .serverFailure(status)
        }
    }
}

private struct FirestoreVaultDocument: Codable {
    struct Fields: Codable {
        let documentType: FirestoreStringValue
        let schemaVersion: FirestoreIntegerValue
        let payload: FirestoreBytesValue
    }
    let fields: Fields
}

private struct FirestoreStringValue: Codable {
    let stringValue: String
}

private struct FirestoreIntegerValue: Codable {
    let integerValue: String
}

private struct FirestoreBytesValue: Codable {
    let bytesValue: String
}

private extension JSONEncoder {
    static var firestoreVaultPayload: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var firestoreVaultPayload: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
