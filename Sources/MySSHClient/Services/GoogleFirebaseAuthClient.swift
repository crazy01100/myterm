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

enum GoogleFirebaseAuthError: LocalizedError {
    case invalidAuthorizationURL
    case invalidRedirectURI
    case invalidHTTPResponse
    case googleTokenExchangeFailed(Int, String)
    case missingGoogleIDToken
    case firebaseSignInFailed(Int)
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
        case .firebaseRefreshFailed(let status): "Google 登入狀態更新失敗（HTTP \(status)）。"
        case .invalidResponse: "登入服務回傳的資料格式不正確。"
        }
    }
}

struct GoogleFirebaseAuthClient: Sendable {
    let configuration: CloudConfiguration

    func authorizationURL(
        redirectURI: URL,
        pkce: OAuthPKCE,
        state: String,
        nonce: String
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
        guard let url = components?.url else { throw GoogleFirebaseAuthError.invalidAuthorizationURL }
        return url
    }

    func signIn(
        authorizationCode: String,
        redirectURI: URL,
        pkceVerifier: String,
        nonce: String
    ) async throws -> FirebaseSession {
        let googleIDToken = try await exchangeGoogleCode(
            authorizationCode,
            redirectURI: redirectURI,
            pkceVerifier: pkceVerifier
        )
        try GoogleIDTokenClaimsValidator.validate(
            idToken: googleIDToken,
            expectedClientID: configuration.googleDesktopClientID,
            expectedNonce: nonce
        )
        return try await exchangeFirebaseSession(googleIDToken: googleIDToken, requestURI: redirectURI)
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try statusCode(response)
        guard (200..<300).contains(status) else {
            throw GoogleFirebaseAuthError.googleTokenExchangeFailed(
                status,
                Self.googleErrorDiagnostic(from: data)
            )
        }
        let payload = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try statusCode(response)
        guard (200..<300).contains(status) else {
            throw GoogleFirebaseAuthError.firebaseSignInFailed(status)
        }
        let payload = try JSONDecoder().decode(FirebaseSignInResponse.self, from: data)
        return FirebaseSession(
            account: FirebaseAccount(
                uid: payload.localID,
                email: payload.email,
                displayName: payload.displayName
            ),
            idToken: payload.idToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn) ?? 3600)
        )
    }

    private func formBody(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func statusCode(_ response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else {
            throw GoogleFirebaseAuthError.invalidHTTPResponse
        }
        return response.statusCode
    }

    /// Google token errors contain a short OAuth error code and description.
    /// Only these fields are surfaced; the response body and authorization
    /// code are never logged or displayed.
    static func googleErrorDiagnostic(from data: Data) -> String {
        guard let payload = try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data) else {
            return "unknown_error"
        }
        let code = sanitizeDiagnostic(payload.error, fallback: "unknown_error", limit: 64)
        guard let description = payload.errorDescription else { return code }
        let safeDescription = sanitizeDiagnostic(description, fallback: "", limit: 180)
        return safeDescription.isEmpty ? code : "\(code): \(safeDescription)"
    }

    private static func sanitizeDiagnostic(_ value: String, fallback: String, limit: Int) -> String {
        let visible = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = visible
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(limit))
    }
}

private struct GoogleOAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
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
