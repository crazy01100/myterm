import CryptoKit
import Foundation
import Security

enum OAuthSecurityError: LocalizedError, Equatable {
    case invalidRandomByteCount
    case randomGenerationFailed(OSStatus)
    case invalidCallback
    case callbackPathMismatch
    case providerError(String)
    case missingAuthorizationCode
    case missingState
    case stateMismatch
    case invalidIDToken
    case invalidIssuer
    case invalidAudience
    case invalidNonce
    case expiredIDToken

    var errorDescription: String? {
        switch self {
        case .invalidRandomByteCount: "OAuth 安全亂數長度不正確。"
        case .randomGenerationFailed(let status): "無法產生 OAuth 安全亂數（\(status)）。"
        case .invalidCallback: "Google 登入回呼格式不正確。"
        case .callbackPathMismatch: "Google 登入回呼路徑不正確。"
        case .providerError(let message): "Google 拒絕登入：\(message)"
        case .missingAuthorizationCode: "Google 沒有回傳授權碼。"
        case .missingState: "Google 登入回呼缺少 state。"
        case .stateMismatch: "Google 登入回呼驗證失敗，已取消登入。"
        case .invalidIDToken: "Google 身分 Token 格式不正確。"
        case .invalidIssuer: "Google 身分 Token 發行者不正確。"
        case .invalidAudience: "Google 身分 Token 不屬於這個 MyTerm OAuth Client。"
        case .invalidNonce: "Google 身分 Token 的 nonce 驗證失敗。"
        case .expiredIDToken: "Google 身分 Token 已過期。"
        }
    }
}

enum OAuthBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

enum OAuthSecureRandom {
    static func base64URL(byteCount: Int) throws -> String {
        guard byteCount > 0 else { throw OAuthSecurityError.invalidRandomByteCount }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OAuthSecurityError.randomGenerationFailed(status)
        }
        return OAuthBase64URL.encode(Data(bytes))
    }
}

struct OAuthPKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String

    static func generate() throws -> Self {
        let verifier = try OAuthSecureRandom.base64URL(byteCount: 64)
        return Self(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return OAuthBase64URL.encode(Data(digest))
    }
}

struct OAuthCallback: Equatable, Sendable {
    static let path = "/oauth2/callback"

    let code: String
    let state: String

    static func parse(requestTarget: String) throws -> Self {
        guard let components = URLComponents(string: "http://127.0.0.1\(requestTarget)") else {
            throw OAuthSecurityError.invalidCallback
        }
        guard components.path == path else { throw OAuthSecurityError.callbackPathMismatch }
        let items = components.queryItems ?? []
        if let providerError = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value
            throw OAuthSecurityError.providerError(description ?? providerError)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthSecurityError.missingAuthorizationCode
        }
        guard let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            throw OAuthSecurityError.missingState
        }
        return Self(code: code, state: state)
    }
}

enum OAuthConstantTime {
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let length = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<length {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

private struct GoogleIDTokenClaims: Decodable {
    let issuer: String
    let audience: String
    let expiration: TimeInterval
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case audience = "aud"
        case expiration = "exp"
        case nonce
    }
}

enum GoogleIDTokenClaimsValidator {
    /// The token is received directly from Google's TLS token endpoint and is
    /// subsequently verified again by Firebase. This local validation binds the
    /// response to this OAuth request before it leaves the Mac.
    static func validate(
        idToken: String,
        expectedClientID: String,
        expectedNonce: String,
        now: Date = .now
    ) throws {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = OAuthBase64URL.decode(String(segments[1])),
              let claims = try? JSONDecoder().decode(GoogleIDTokenClaims.self, from: payload) else {
            throw OAuthSecurityError.invalidIDToken
        }
        guard claims.issuer == "https://accounts.google.com" || claims.issuer == "accounts.google.com" else {
            throw OAuthSecurityError.invalidIssuer
        }
        guard OAuthConstantTime.equal(claims.audience, expectedClientID) else {
            throw OAuthSecurityError.invalidAudience
        }
        guard OAuthConstantTime.equal(claims.nonce, expectedNonce) else {
            throw OAuthSecurityError.invalidNonce
        }
        guard claims.expiration > now.timeIntervalSince1970 else {
            throw OAuthSecurityError.expiredIDToken
        }
    }
}
