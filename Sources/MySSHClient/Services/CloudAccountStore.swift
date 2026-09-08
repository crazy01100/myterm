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

    var signedInAccount: FirebaseAccount? {
        guard case .signedIn(let account) = self else { return nil }
        return account
    }
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
    private var tokenRefreshTask: Task<String, Error>?
    private var credentialGeneration = 0
    private enum RestoreDisposition { case initial, retryableFailure, blocked, restored }
    private var restoreDisposition: RestoreDisposition = .initial
    private var restorationTask: Task<Void, Never>?

    var canRetrySessionRestore: Bool { restoreDisposition == .retryableFailure }

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

    func restoreIfPossible(retryTransientFailure: Bool = false) async {
        if let restorationTask {
            await restorationTask.value
            return
        }
        guard restoreDisposition == .initial || (retryTransientFailure && canRetrySessionRestore) else { return }
        guard let client, let configuration else { return }
        let generation = credentialGeneration
        restoreDisposition = .blocked
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
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
                guard generation == credentialGeneration, !Task.isCancelled else { return }
                try persist(session)
                restoreDisposition = .restored
            } catch {
                guard generation == credentialGeneration else { return }
                restoreDisposition = Self.isTransientRestoreError(error) ? .retryableFailure : .blocked
                state = .failed(canRetrySessionRestore
                    ? "暫時無法恢復 Google 登入，將於下一次同步時再試。"
                    : "無法恢復 Google 登入，請檢查帳號或重新登入。")
            }
        }
        restorationTask = task
        await task.value
        if generation == credentialGeneration { restorationTask = nil }
    }

    private static func isTransientRestoreError(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(error.code)
        }
        if case GoogleFirebaseAuthError.firebaseRefreshFailed(let status) = error {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }

    private func stopSessionRestoration() {
        restoreDisposition = .blocked
        restorationTask?.cancel()
        restorationTask = nil
    }

    func signIn() {
        guard signInTask == nil, let client, configuration != nil else { return }
        credentialGeneration += 1
        stopSessionRestoration()
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        let generation = credentialGeneration
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
                guard !Task.isCancelled, generation == self.credentialGeneration else { return }
                try persist(session)
            } catch is CancellationError {
                guard generation == self.credentialGeneration else { return }
                self.state = .signedOut
            } catch {
                guard generation == self.credentialGeneration else { return }
                self.state = .failed(error.localizedDescription)
            }
            self.signInTask = nil
        }
    }

    func cancelSignIn() {
        credentialGeneration += 1
        stopSessionRestoration()
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        signInTask?.cancel()
        signInTask = nil
        state = .signedOut
    }

    func signOut() {
        credentialGeneration += 1
        stopSessionRestoration()
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
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
        credentialGeneration += 1
        stopSessionRestoration()
        state = .signedOut
    }

    func validIDToken() async throws -> String {
        guard case .signedIn(let account) = state,
              let client,
              let configuration else {
            throw CloudAccountStoreError.notSignedIn
        }
        if let currentIDToken,
           let currentTokenExpiresAt,
           currentTokenExpiresAt.timeIntervalSinceNow > 90 {
            return currentIDToken
        }
        if let tokenRefreshTask { return try await tokenRefreshTask.value }
        guard let refreshToken = try CloudSessionKeychainStore.refreshToken(
            projectID: configuration.firebaseProjectID,
            legacyImportPolicy: legacySessionImportPolicy
        ) else {
            throw CloudAccountStoreError.notSignedIn
        }
        let generation = credentialGeneration
        let task = Task { @MainActor in
            let session = try await client.refresh(refreshToken: refreshToken)
            try Task.checkCancellation()
            guard self.credentialGeneration == generation,
                  self.state.signedInAccount?.uid == account.uid,
                  session.account.uid == account.uid else { throw CancellationError() }
            try self.persist(session)
            return session.idToken
        }
        tokenRefreshTask = task
        defer { if credentialGeneration == generation { tokenRefreshTask = nil } }
        return try await task.value
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
