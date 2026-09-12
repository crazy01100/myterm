import Foundation

struct FirebaseAccount: Equatable, Sendable {
    let uid: String
    let email: String?
    let displayName: String?

    var title: String { displayName ?? email ?? "Google 使用者" }
}

struct FirebaseSession: Sendable {
    let account: FirebaseAccount
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
}

enum GoogleFirebaseAuthError: LocalizedError, Equatable {
    case invalidAuthorizationURL
    case invalidRedirectURI
    case invalidHTTPResponse
    case googleTokenExchangeFailed(Int, String)
    case missingGoogleIDToken
    case firebaseSignInFailed(Int)
    case cloudSyncAccessUnavailable
    case accountConfirmationRequired
    case additionalVerificationRequired
    case accountDisabled
    case firebaseSignInRejected
    case firebaseRefreshFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL: "無法建立 Google 登入網址。"
        case .invalidRedirectURI: "Google 登入本機回呼網址無效。"
        case .invalidHTTPResponse: "登入服務回傳了無效的網路回應。"
        case .googleTokenExchangeFailed(let status, let reason):
            "Google 登入交換失敗（HTTP \(status)，\(reason)）。"
        case .missingGoogleIDToken: "Google 沒有回傳身分 Token。"
        case .firebaseSignInFailed(let status): "Google 登入驗證失敗（HTTP \(status)）。"
        case .cloudSyncAccessUnavailable:
            "此雲端同步服務暫未開放此 Google 帳號使用。既有使用者請確認使用原本的 Google 帳號；如需自行架設同步服務，請參考專案指南。本機功能不受影響。"
        case .accountConfirmationRequired:
            "此 Google 帳號需要先確認既有的登入身分，暫時無法完成同步服務登入。請聯絡此同步服務的管理者協助確認。"
        case .additionalVerificationRequired:
            "同步服務要求額外的身分驗證，目前 MyTerm 尚無法完成此驗證。請聯絡此同步服務的管理者。"
        case .accountDisabled:
            "此帳號已被同步服務停用。請聯絡此同步服務的管理者。"
        case .firebaseSignInRejected:
            "同步服務未接受這次登入。請稍後重新嘗試；若持續發生，請聯絡此同步服務的管理者。"
        case .firebaseRefreshFailed(let status): "Google 登入狀態更新失敗（HTTP \(status)）。"
        case .invalidResponse: "登入服務回傳的資料格式不正確。"
        }
    }
}

struct GoogleFirebaseAuthClient: Sendable {
    let configuration: CloudConfiguration
    private let urlSession: URLSession

    init(configuration: CloudConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    func authorizationURL(
        redirectURI: URL,
        pkce: OAuthPKCE,
        state: String,
        nonce: String,
        selectAccount: Bool = false
    ) throws -> URL {
        guard redirectURI.scheme == "http", redirectURI.host == "127.0.0.1" else {
            throw GoogleFirebaseAuthError.invalidRedirectURI
        }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.googleDesktopClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce)
        ]
        if selectAccount { components?.queryItems?.append(URLQueryItem(name: "prompt", value: "select_account")) }
        guard let url = components?.url else { throw GoogleFirebaseAuthError.invalidAuthorizationURL }
        return url
    }

    func signIn(
        authorizationCode: String,
        redirectURI: URL,
        pkceVerifier: String,
        nonce: String
    ) async throws -> FirebaseSession {
        let credential = try await prepareSignIn(authorizationCode: authorizationCode, redirectURI: redirectURI,
                                                  pkceVerifier: pkceVerifier, nonce: nonce)
        return try await completeSignIn(credential)
    }

    func prepareSignIn(authorizationCode: String, redirectURI: URL, pkceVerifier: String,
                       nonce: String) async throws -> GoogleSignInRetryCredential {
        let googleIDToken = try await exchangeGoogleCode(
            authorizationCode,
            redirectURI: redirectURI,
            pkceVerifier: pkceVerifier
        )
        let expiration = try GoogleIDTokenClaimsValidator.validate(
            idToken: googleIDToken,
            expectedClientID: configuration.googleDesktopClientID,
            expectedNonce: nonce
        )
        try Task.checkCancellation()
        return GoogleSignInRetryCredential(idToken: googleIDToken, clientID: configuration.googleDesktopClientID,
            projectID: configuration.firebaseProjectID, requestURI: redirectURI, expiresAt: expiration)
    }

    func completeSignIn(_ credential: GoogleSignInRetryCredential) async throws -> FirebaseSession {
        try Task.checkCancellation()
        let token = try credential.tokenForExchange(clientID: configuration.googleDesktopClientID,
                                                     projectID: configuration.firebaseProjectID)
        return try await exchangeFirebaseSession(googleIDToken: token, requestURI: credential.requestURI)
    }

    func refresh(refreshToken: String) async throws -> FirebaseSession {
        var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token")
        components?.queryItems = [URLQueryItem(name: "key", value: configuration.firebaseAPIKey)]
        guard let url = components?.url else { throw GoogleFirebaseAuthError.invalidAuthorizationURL }
        let body = formBody([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await urlSession.data(for: request)
        let status = try statusCode(response)
        guard (200..<300).contains(status) else {
            throw GoogleFirebaseAuthError.firebaseRefreshFailed(status)
        }
        let payload = try JSONDecoder().decode(FirebaseRefreshResponse.self, from: data)
        let account = try await lookupAccount(idToken: payload.idToken, fallbackUID: payload.userID)
        return FirebaseSession(
            account: account,
            idToken: payload.idToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn) ?? 3600)
        )
    }

    private func lookupAccount(idToken: String, fallbackUID: String) async throws -> FirebaseAccount {
        var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:lookup")
        components?.queryItems = [URLQueryItem(name: "key", value: configuration.firebaseAPIKey)]
        guard let url = components?.url else { throw GoogleFirebaseAuthError.invalidAuthorizationURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["idToken": idToken])
        let (data, response) = try await urlSession.data(for: request)
        let status = try statusCode(response)
        guard (200..<300).contains(status) else {
            throw GoogleFirebaseAuthError.firebaseRefreshFailed(status)
        }
        let payload = try JSONDecoder().decode(FirebaseLookupResponse.self, from: data)
        guard let user = payload.users.first else { throw GoogleFirebaseAuthError.invalidResponse }
        return FirebaseAccount(
            uid: user.localID.isEmpty ? fallbackUID : user.localID,
            email: user.email,
            displayName: user.displayName
        )
    }

    private func exchangeGoogleCode(
        _ code: String,
        redirectURI: URL,
        pkceVerifier: String
    ) async throws -> String {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw GoogleFirebaseAuthError.invalidAuthorizationURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            URLQueryItem(name: "client_id", value: configuration.googleDesktopClientID),
            URLQueryItem(name: "client_secret", value: configuration.googleDesktopClientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: pkceVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString)
        ])
        let (data, response) = try await urlSession.data(for: request)
        let status = try statusCode(response)
        guard (200..<300).contains(status) else {
            throw GoogleFirebaseAuthError.googleTokenExchangeFailed(
                status,
                Self.googleErrorDiagnostic(from: data)
            )
        }
        guard let payload = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            throw GoogleFirebaseAuthError.invalidResponse
        }
        guard let idToken = payload.idToken, !idToken.isEmpty else {
            throw GoogleFirebaseAuthError.missingGoogleIDToken
        }
        return idToken
    }

    private func exchangeFirebaseSession(googleIDToken: String, requestURI: URL) async throws -> FirebaseSession {
        var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp")
        components?.queryItems = [URLQueryItem(name: "key", value: configuration.firebaseAPIKey)]
        guard let url = components?.url else { throw GoogleFirebaseAuthError.invalidAuthorizationURL }
        let postBody = String(data: formBody([
            URLQueryItem(name: "id_token", value: googleIDToken),
            URLQueryItem(name: "providerId", value: "google.com")
        ]), encoding: .utf8) ?? ""
        let body: [String: Any] = [
            "postBody": postBody,
            "requestUri": requestURI.absoluteString,
            "returnIdpCredential": true,
            "returnSecureToken": true
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        let status = try statusCode(response)
        return try Self.firebaseSession(from: data, status: status)
    }

    /// HTTP success is not proof that the identity exchange completed. Inspect
    /// Firebase's incomplete/error envelopes before decoding or persisting tokens.
    static func firebaseSession(from data: Data, status: Int) throws -> FirebaseSession {
        guard (200..<300).contains(status) else {
            throw Self.firebaseSignInError(from: data, status: status)
        }
        guard data.count <= 262_144,
              let envelope = try? JSONDecoder().decode(FirebaseSignInEnvelope.self, from: data) else {
            throw GoogleFirebaseAuthError.invalidResponse
        }
        if envelope.needConfirmation == true { throw GoogleFirebaseAuthError.accountConfirmationRequired }
        if envelope.mfaPendingCredential != nil { throw GoogleFirebaseAuthError.additionalVerificationRequired }
        if envelope.needEmail == true { throw GoogleFirebaseAuthError.accountConfirmationRequired }
        if let message = envelope.errorMessage ?? envelope.error?.message {
            throw knownFirebaseSignInError(message) ?? GoogleFirebaseAuthError.firebaseSignInRejected
        }
        guard let payload = try? JSONDecoder().decode(FirebaseSignInResponse.self, from: data),
              !payload.localID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let lifetime = TimeInterval(payload.expiresIn), lifetime.isFinite, lifetime > 0, lifetime <= 86_400 else {
            throw GoogleFirebaseAuthError.invalidResponse
        }
        return FirebaseSession(
            account: FirebaseAccount(
                uid: payload.localID,
                email: payload.email,
                displayName: payload.displayName
            ),
            idToken: payload.idToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
    }

    private func formBody(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    /// Interpret known sign-in errors without displaying server-provided text.
    /// Never display the backend body, which can contain account/token details.
    static func firebaseSignInError(from data: Data, status: Int) -> GoogleFirebaseAuthError {
        if (status == 400 || status == 403), data.count <= 16_384,
           let payload = try? JSONDecoder().decode(FirebaseErrorResponse.self, from: data),
           let error = knownFirebaseSignInError(payload.error.message) {
            return error
        }
        return .firebaseSignInFailed(status)
    }

    private static func knownFirebaseSignInError(_ message: String) -> GoogleFirebaseAuthError? {
        let code = message.split(separator: ":", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case "ADMIN_ONLY_OPERATION": return .cloudSyncAccessUnavailable
        case "EMAIL_EXISTS", "FEDERATED_USER_ID_ALREADY_LINKED": return .accountConfirmationRequired
        case "USER_DISABLED": return .accountDisabled
        default: return nil
        }
    }

    private func statusCode(_ response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else {
            throw GoogleFirebaseAuthError.invalidHTTPResponse
        }
        return response.statusCode
    }

    /// Only allowlisted OAuth codes are surfaced. Provider descriptions can
    /// contain request/account details and must not become UI diagnostics.
    static func googleErrorDiagnostic(from data: Data) -> String {
        guard data.count <= 16_384,
              let payload = try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data) else {
            return "unknown_error"
        }
        let allowed = ["invalid_grant", "invalid_client", "unauthorized_client", "invalid_request",
                       "unsupported_grant_type", "access_denied", "invalid_scope",
                       "temporarily_unavailable", "server_error"]
        return allowed.contains(payload.error) ? payload.error : "unknown_error"
    }
}

private struct FirebaseErrorResponse: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}

private struct FirebaseSignInEnvelope: Decodable {
    let errorMessage: String?
    let error: FirebaseErrorResponse.Detail?
    let needConfirmation: Bool?
    let needEmail: Bool?
    let mfaPendingCredential: String?
}

private struct GoogleOAuthErrorResponse: Decodable {
    let error: String
}

private struct GoogleTokenResponse: Decodable {
    let idToken: String?

    enum CodingKeys: String, CodingKey { case idToken = "id_token" }
}

private struct FirebaseSignInResponse: Decodable {
    let localID: String
    let email: String?
    let displayName: String?
    let idToken: String
    let refreshToken: String
    let expiresIn: String

    enum CodingKeys: String, CodingKey {
        case localID = "localId"
        case email, displayName, idToken, refreshToken, expiresIn
    }
}

private struct FirebaseRefreshResponse: Decodable {
    let userID: String
    let idToken: String
    let refreshToken: String
    let expiresIn: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct FirebaseLookupResponse: Decodable {
    let users: [FirebaseLookupUser]
}

private struct FirebaseLookupUser: Decodable {
    let localID: String
    let email: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case localID = "localId"
        case email, displayName
    }
}
