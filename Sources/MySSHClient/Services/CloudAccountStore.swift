import AppKit
import Combine
import Foundation

enum CloudAccountState: Equatable {
    case unavailable(String)
    case signedOut
    case restoring
    case signingIn
    case signedIn(FirebaseAccount)
    case failed(String)
}

enum CloudAccountStoreError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        "尚未登入 Google 帳號。"
    }
}

@MainActor
final class CloudAccountStore: ObservableObject {
    @Published private(set) var state: CloudAccountState

    private let client: GoogleFirebaseAuthClient?
    private let configuration: CloudConfiguration?
    private let legacySessionImportPolicy: CloudSessionLegacyImportPolicy
    private var currentIDToken: String?
    private var currentTokenExpiresAt: Date?
    private var signInTask: Task<Void, Never>?
    private var didAttemptRestore = false

    init(bundle: Bundle = .main) {
        legacySessionImportPolicy = .current(bundle: bundle)
        do {
            let configuration = try CloudConfiguration.load(bundle: bundle)
            self.configuration = configuration
            client = GoogleFirebaseAuthClient(configuration: configuration)
            state = .signedOut
        } catch {
            configuration = nil
            client = nil
            state = .unavailable(error.localizedDescription)
        }
    }

    func restoreIfPossible() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard let client, let configuration else { return }
        do {
            try CloudSessionKeychainStore.resetIsolatedChannelSessionIfNeeded(
                projectID: configuration.firebaseProjectID,
                legacyImportPolicy: legacySessionImportPolicy
            )
            guard let refreshToken = try CloudSessionKeychainStore.refreshToken(
                projectID: configuration.firebaseProjectID,
                legacyImportPolicy: legacySessionImportPolicy
            ) else {
                state = .signedOut
                return
            }
            state = .restoring
            let session = try await client.refresh(refreshToken: refreshToken)
            try persist(session)
        } catch {
            state = .failed("無法恢復 Google 登入狀態：\(error.localizedDescription)")
        }
    }

    func signIn() {
        guard signInTask == nil, let client, configuration != nil else { return }
        state = .signingIn
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pkce = try OAuthPKCE.generate()
                let stateValue = try OAuthSecureRandom.base64URL(byteCount: 32)
                let nonce = try OAuthSecureRandom.base64URL(byteCount: 32)
                let listener = try await LoopbackOAuthListener.start(expectedState: stateValue)
                guard let redirectURI = listener.redirectURI else {
                    listener.cancel()
                    throw GoogleFirebaseAuthError.invalidRedirectURI
                }
                let authorizationURL = try client.authorizationURL(
                    redirectURI: redirectURI,
                    pkce: pkce,
                    state: stateValue,
                    nonce: nonce
                )
                guard NSWorkspace.shared.open(authorizationURL) else {
                    listener.cancel()
                    throw GoogleFirebaseAuthError.invalidAuthorizationURL
                }
                let callback = try await listener.waitForCallback()
                let session = try await client.signIn(
                    authorizationCode: callback.code,
                    redirectURI: redirectURI,
                    pkceVerifier: pkce.verifier,
                    nonce: nonce
                )
                try persist(session)
            } catch is CancellationError {
                self.state = .signedOut
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        state = .signedOut
    }

    func signOut() {
        signInTask?.cancel()
        signInTask = nil
        currentIDToken = nil
        currentTokenExpiresAt = nil
        guard let configuration else { return }
        do {
            let result = try CloudSessionKeychainStore.deleteRefreshToken(
                projectID: configuration.firebaseProjectID
            )
            if case .manualCleanupRequired(let status) = result {
                throw KeychainStoreError.operationFailed(status)
            }
            state = .signedOut
        } catch {
            state = .failed("無法清除這台 Mac 的登入狀態：\(error.localizedDescription)")
        }
    }

    func retryAfterFailure() {
        guard client != nil else { return }
        state = .signedOut
    }

    func validIDToken() async throws -> String {
        guard case .signedIn = state,
              let client,
              let configuration else {
            throw CloudAccountStoreError.notSignedIn
        }
        if let currentIDToken,
           let currentTokenExpiresAt,
           currentTokenExpiresAt.timeIntervalSinceNow > 90 {
            return currentIDToken
        }
        guard let refreshToken = try CloudSessionKeychainStore.refreshToken(
            projectID: configuration.firebaseProjectID,
            legacyImportPolicy: legacySessionImportPolicy
        ) else {
            throw CloudAccountStoreError.notSignedIn
        }
        let session = try await client.refresh(refreshToken: refreshToken)
        try persist(session)
        return session.idToken
    }

    var firebaseProjectID: String? { configuration?.firebaseProjectID }

    private func persist(_ session: FirebaseSession) throws {
        guard let configuration else { return }
        try CloudSessionKeychainStore.saveRefreshToken(
            session.refreshToken,
            projectID: configuration.firebaseProjectID
        )
        currentIDToken = session.idToken
        currentTokenExpiresAt = session.expiresAt
        state = .signedIn(session.account)
    }
}
