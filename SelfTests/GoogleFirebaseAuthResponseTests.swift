import Foundation

// This standalone process intercepts every URLSession request. It has no App
// store, Keychain, real configuration, or route to the production backend.
private final class AuthResponseProtocol: URLProtocol {
    static var firebaseBody = Data()
    static var firebaseStatus = 200
    static var googleBody: Data?
    static var googleStatus = 200
    static var firebaseRequests = 0
    static var googleRequests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        let status: Int
        switch request.url?.host {
        case "oauth2.googleapis.com":
            Self.googleRequests += 1
            status = Self.googleStatus
            if let body = Self.googleBody { data = body }
            else {
                let claims: [String: Any] = ["iss": "https://accounts.google.com", "aud": "synthetic.apps.googleusercontent.com",
                    "nonce": "synthetic-nonce", "exp": Date().addingTimeInterval(3600).timeIntervalSince1970]
                let token = "header." + OAuthBase64URL.encode(try! JSONSerialization.data(withJSONObject: claims)) + ".signature"
                data = try! JSONSerialization.data(withJSONObject: ["id_token": token])
            }
        case "identitytoolkit.googleapis.com":
            Self.firebaseRequests += 1; data = Self.firebaseBody; status = Self.firebaseStatus
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main private struct AuthResponseTests {
    static func main() async {
        let transportConfig = URLSessionConfiguration.ephemeral
        transportConfig.protocolClasses = [AuthResponseProtocol.self]
        transportConfig.urlCache = nil
        let transport = URLSession(configuration: transportConfig)
        defer { transport.invalidateAndCancel() }
        let client = GoogleFirebaseAuthClient(configuration: CloudConfiguration(
            googleDesktopClientID: "synthetic.apps.googleusercontent.com", googleDesktopClientSecret: "synthetic-secret",
            firebaseAPIKey: "synthetic-key", firebaseProjectID: "demo-myterm"), urlSession: transport)
        var passed = 0
        var failed = 0
        let success: [String: Any] = ["localId": "synthetic-uid", "idToken": "synthetic-token",
            "refreshToken": "synthetic-refresh", "expiresIn": "3600"]
        func run(_ name: String, _ body: Any, status: Int = 200, expected: GoogleFirebaseAuthError? = nil,
                 google: Bool = false) async {
            let bytes = (body as? Data) ?? (try! JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed))
            AuthResponseProtocol.firebaseRequests = 0
            AuthResponseProtocol.firebaseBody = google ? try! JSONSerialization.data(withJSONObject: success) : bytes
            AuthResponseProtocol.firebaseStatus = google ? 200 : status
            AuthResponseProtocol.googleBody = google ? bytes : nil
            AuthResponseProtocol.googleStatus = google ? status : 200
            do {
                let session = try await client.signIn(authorizationCode: "synthetic-code",
                    redirectURI: URL(string: "http://127.0.0.1:12345/oauth2/callback")!, pkceVerifier: "synthetic-verifier", nonce: "synthetic-nonce")
                guard expected == nil, session.account.uid == "synthetic-uid", session.idToken == "synthetic-token",
                      session.refreshToken == "synthetic-refresh", session.expiresAt.timeIntervalSinceNow > 3500 else {
                    failed += 1; print("FAIL: \(name) unexpectedly accepted session"); return
                }
            } catch let error as GoogleFirebaseAuthError {
                guard error == expected, !error.localizedDescription.contains("PRIVATE_SENTINEL"),
                      !google || AuthResponseProtocol.firebaseRequests == 0 else {
                    failed += 1; print("FAIL: \(name) wrong typed error or privacy boundary"); return
                }
            } catch {
                failed += 1; print("FAIL: \(name) leaked unclassified error"); return
            }
            passed += 1; print("PASS: \(name)")
        }
        for status in [400, 403] {
            await run("restricted HTTP \(status)", ["error": ["message": "ADMIN_ONLY_OPERATION : PRIVATE_SENTINEL"]], status: status, expected: .cloudSyncAccessUnavailable)
        }
        await run("HTTP 200 restriction", ["errorMessage": "ADMIN_ONLY_OPERATION : PRIVATE_SENTINEL"], expected: .cloudSyncAccessUnavailable)
        await run("HTTP 200 nested error", ["error": ["message": "ADMIN_ONLY_OPERATION"]], expected: .cloudSyncAccessUnavailable)
        for code in ["EMAIL_EXISTS", "FEDERATED_USER_ID_ALREADY_LINKED"] {
            await run(code, ["errorMessage": code], expected: .accountConfirmationRequired)
        }
        await run("confirmation takes precedence over apparent success", success.merging(["needConfirmation": true]) { _, new in new }, expected: .accountConfirmationRequired)
        await run("missing email", ["needEmail": true], expected: .accountConfirmationRequired)
        await run("MFA pending", ["mfaPendingCredential": "PRIVATE_SENTINEL"], expected: .additionalVerificationRequired)
        await run("disabled user", ["errorMessage": "USER_DISABLED"], expected: .accountDisabled)
        await run("unknown business error", ["errorMessage": "PRIVATE_SENTINEL"], expected: .firebaseSignInRejected)
        await run("empty business error", ["errorMessage": ""], expected: .firebaseSignInRejected)
        await run("business error overrides tokens", success.merging(["errorMessage": "ADMIN_ONLY_OPERATION"]) { _, new in new }, expected: .cloudSyncAccessUnavailable)
        for status in [429, 500, 503] {
            await run("server/quota is not admission \(status)", ["error": ["message": "ADMIN_ONLY_OPERATION"]], status: status, expected: .firebaseSignInFailed(status))
        }
        for key in ["localId", "idToken", "refreshToken", "expiresIn"] {
            var missing = success; missing.removeValue(forKey: key)
            await run("missing \(key)", missing, expected: .invalidResponse)
            var empty = success; empty[key] = " "
            await run("empty \(key)", empty, expected: .invalidResponse)
        }
        for value in ["0", "-1", "nan", "inf", "86401", "PRIVATE_SENTINEL"] {
            await run("invalid token lifetime \(value)", success.merging(["expiresIn": value]) { _, new in new }, expected: .invalidResponse)
        }
        for body: Any in [Data("not-json".utf8), [], ["needConfirmation": "true"], ["errorMessage": 42], Data(repeating: 65, count: 262145)] {
            await run("malformed/oversized response", body, expected: .invalidResponse)
        }
        await run("successful session with optional profile absent", success)
        await run("successful session with false confirmation", success.merging(["needConfirmation": false]) { _, new in new })
        await run("Google missing ID token", [:], expected: .missingGoogleIDToken, google: true)
        await run("Google malformed response", Data("not-json".utf8), expected: .invalidResponse, google: true)
        await run("Google ID token type mismatch", ["id_token": 42], expected: .invalidResponse, google: true)
        await run("Google error description is private", ["error": "invalid_grant", "error_description": "PRIVATE_SENTINEL"], status: 400,
                  expected: .googleTokenExchangeFailed(400, "invalid_grant"), google: true)
        await run("Google unknown code is private", ["error": "PRIVATE_SENTINEL"], status: 400,
                  expected: .googleTokenExchangeFailed(400, "unknown_error"), google: true)
        do {
            AuthResponseProtocol.googleBody = nil; AuthResponseProtocol.googleStatus = 200
            AuthResponseProtocol.firebaseStatus = 200; AuthResponseProtocol.googleRequests = 0
            AuthResponseProtocol.firebaseRequests = 0
            let credential = try await client.prepareSignIn(authorizationCode: "synthetic-code",
                redirectURI: URL(string: "http://127.0.0.1:12345/oauth2/callback")!, pkceVerifier: "synthetic-verifier", nonce: "synthetic-nonce")
            AuthResponseProtocol.firebaseBody = try JSONSerialization.data(withJSONObject: ["errorMessage": "ADMIN_ONLY_OPERATION"])
            do { _ = try await client.completeSignIn(credential); failed += 1 }
            catch GoogleFirebaseAuthError.cloudSyncAccessUnavailable { passed += 1 }
            AuthResponseProtocol.firebaseBody = try JSONSerialization.data(withJSONObject: success)
            let result = try await client.completeSignIn(credential)
            if result.account.uid == "synthetic-uid", AuthResponseProtocol.googleRequests == 1, AuthResponseProtocol.firebaseRequests == 2 {
                passed += 1; print("PASS: prepared Google credential retries only Firebase after admission changes")
            } else { failed += 1 }
            let url = try client.authorizationURL(redirectURI: credential.requestURI, pkce: OAuthPKCE.generate(),
                state: "state", nonce: "nonce", selectAccount: true)
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "prompt", value: "select_account")) == true {
                passed += 1; print("PASS: switching accounts explicitly requests the Google account chooser")
            } else { failed += 1 }
        } catch { failed += 1; print("FAIL: prepared credential exchange") }
        print("Auth response tests: \(passed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
