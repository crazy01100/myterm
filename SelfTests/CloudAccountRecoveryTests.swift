import AppKit
import Foundation

// These collaborators are linked only into this standalone test executable.
// CloudAccountStore, SyncSettingsStore and AutomaticSyncCoordinator are real app source.
// No Google requests, Keychain queries, or real account files are used.
struct FirebaseAccount: Equatable, Sendable {
    let uid: String
    let email: String?
    let displayName: String?
}
struct FirebaseSession {
    let account: FirebaseAccount
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
}
struct CloudConfiguration {
    let firebaseProjectID = "synthetic-project"
    static func load(bundle: Bundle) throws -> Self { Self() }
}
struct CloudSessionLegacyImportPolicy {
    static func current(bundle: Bundle) -> Self { Self() }
}
enum DeletionResult { case removed, manualCleanupRequired(Int32) }
enum KeychainStoreError: Error { case operationFailed(Int32) }
@MainActor enum SyntheticAuth {
    enum Mode { case offline, online, revoked, holding, busy, certificateFailure, restricted }
    static var mode: Mode = .offline
    static var attempts = 0
    static var saves = 0
    static var hasToken = true
    static var release: CheckedContinuation<Void, Never>?
    static var browserOpens = 0
    static var googleExchanges = 0
    static var credentialLifetime: TimeInterval = 3600
    static func reset(_ mode: Mode) {
        self.mode = mode
        attempts = 0
        saves = 0
        hasToken = true
        release = nil
        browserOpens = 0
        googleExchanges = 0
        credentialLifetime = 3600
    }
}
@MainActor enum CloudSessionKeychainStore {
    static func resetIsolatedChannelSessionIfNeeded(projectID: String, legacyImportPolicy: CloudSessionLegacyImportPolicy) throws {}
    static func refreshToken(projectID: String, legacyImportPolicy: CloudSessionLegacyImportPolicy) throws -> String? {
        SyntheticAuth.hasToken ? "synthetic-only" : nil
    }
    static func saveRefreshToken(_ token: String, projectID: String) throws { SyntheticAuth.saves += 1 }
    static func deleteRefreshToken(projectID: String) throws -> DeletionResult {
        SyntheticAuth.hasToken = false
        return .removed
    }
}
struct OAuthPKCE {
    let verifier = "synthetic"
    static func generate() throws -> Self { Self() }
}
enum OAuthSecureRandom {
    static func base64URL(byteCount: Int) throws -> String { "synthetic" }
}
@MainActor final class LoopbackOAuthListener {
    var redirectURI: URL? { URL(string: "http://127.0.0.1:12345/oauth2/callback") }
    static func start(expectedState: String) async throws -> LoopbackOAuthListener { .init() }
    func cancel() {}
    func waitForCallback() async throws -> (code: String, state: String) { ("synthetic", "synthetic") }
}
enum GoogleFirebaseAuthError: Error {
    case invalidRedirectURI, invalidAuthorizationURL, firebaseRefreshFailed(Int), cloudSyncAccessUnavailable
}
@MainActor struct GoogleFirebaseAuthClient {
    let configuration: CloudConfiguration
    func refresh(refreshToken: String) async throws -> FirebaseSession {
        SyntheticAuth.attempts += 1
        switch SyntheticAuth.mode {
        case .offline: throw URLError(.notConnectedToInternet)
        case .revoked: throw GoogleFirebaseAuthError.firebaseRefreshFailed(400)
        case .busy: throw GoogleFirebaseAuthError.firebaseRefreshFailed(503)
        case .certificateFailure: throw URLError(.serverCertificateUntrusted)
        case .restricted: throw GoogleFirebaseAuthError.cloudSyncAccessUnavailable
        case .holding: await withCheckedContinuation { SyntheticAuth.release = $0 }
        case .online: break
        }
        // Deliberately ignore cancellation to verify the real store's generation fence.
        return FirebaseSession(account: .init(uid: "synthetic-owner", email: nil, displayName: nil),
                               idToken: "synthetic", refreshToken: "synthetic", expiresAt: Date().addingTimeInterval(3600))
    }
    func authorizationURL(redirectURI: URL, pkce: OAuthPKCE, state: String, nonce: String, selectAccount: Bool = false) throws -> URL {
        URL(string: "https://example.test/authorize?selectAccount=\(selectAccount)")!
    }
    func signIn(authorizationCode: String, redirectURI: URL, pkceVerifier: String, nonce: String) async throws -> FirebaseSession {
        try await refresh(refreshToken: "synthetic")
    }
    func prepareSignIn(authorizationCode: String, redirectURI: URL, pkceVerifier: String, nonce: String) async throws -> GoogleSignInRetryCredential {
        SyntheticAuth.googleExchanges += 1
        return .init(idToken: "synthetic-google", clientID: "synthetic-client", projectID: configuration.firebaseProjectID,
                     requestURI: redirectURI, expiresAt: Date().addingTimeInterval(SyntheticAuth.credentialLifetime))
    }
    func completeSignIn(_ credential: GoogleSignInRetryCredential) async throws -> FirebaseSession {
        _ = try credential.tokenForExchange(clientID: "synthetic-client", projectID: configuration.firebaseProjectID)
        return try await refresh(refreshToken: "synthetic")
    }
}

@main struct CloudAccountRecoveryTests {
    @MainActor static func main() async {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if condition { passed += 1 } else { failed += 1 }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw NSError(domain: "SyntheticDeadline", code: 1)
        }
        let suite = "MyTerm-Recovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: "MyTerm-Recovery-\(UUID())")
        let journal = SyncDiagnosticsJournal(file: directory.appending(path: "events.json"))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            SyntheticAuth.reset(.offline)
            let account = CloudAccountStore()
            let settings = SyncSettingsStore(defaults: defaults)
            settings.setContext(availability: .ready, ownerUID: "synthetic-owner")
            try settings.setMetadataSyncEnabled(true)
            settings.setContext(availability: .ready, ownerUID: nil)
            check(settings.sessionRecoveryEnabled && !settings.metadataSyncEnabled,
                  "remembered sync intent permits recovery but never enables unauthenticated data sync")
            var metadataCalls = 0
            var logCalls = 0
            let coordinator = AutomaticSyncCoordinator(defaults: defaults,
                timing: .init(periodic: 0.15, debounce: 0.01, stale: 60, deadline: 1), journal: journal)
            coordinator.configure(context: {
                .init(scope: account.state.signedInAccount?.uid ?? "signed-out", enabled: settings.metadataSyncEnabled)
            }, prepare: {
                settings.setContext(availability: .ready, ownerUID: account.state.signedInAccount?.uid)
            }, canRecoverSession: {
                settings.sessionRecoveryEnabled && account.canRetrySessionRestore
            }, recoverSession: {
                await account.restoreIfPossible(retryTransientFailure: true)
            }, metadata: { _ in metadataCalls += 1; return .completed }, logs: { _ in logCalls += 1; return .completed })
            coordinator.setActive(true)
            await account.restoreIfPossible()
            check(SyntheticAuth.attempts == 1 && account.canRetrySessionRestore, "offline cold start remains eligible for a later recovery")
            for _ in 0..<30 { coordinator.request(.availability); coordinator.request(.localChange) }
            await account.restoreIfPossible()
            SyntheticAuth.mode = .online
            try await Task.sleep(for: .milliseconds(30))
            check(SyntheticAuth.attempts == 1 && metadataCalls == 0 && logCalls == 0,
                  "restoration failure does not cause immediate retries or unauthenticated worker calls")
            try await waitUntil { coordinator.lastSuccessfulSyncAt != nil }
            coordinator.setActive(false)
            check(SyntheticAuth.attempts == 2 && account.state.signedInAccount != nil,
                  "next existing periodic tick restores real CloudAccountStore after offline startup")
            check(metadataCalls == 1 && logCalls == 1, "the recovery tick continues into both sync workers")

            account.signOut()
            await account.restoreIfPossible(retryTransientFailure: true)
            check(account.state == .signedOut && SyntheticAuth.attempts == 2 && !account.canRetrySessionRestore,
                  "explicit sign-out is never silently undone by periodic restoration")

            SyntheticAuth.reset(.revoked)
            let revoked = CloudAccountStore()
            await revoked.restoreIfPossible()
            SyntheticAuth.mode = .online
            await revoked.restoreIfPossible(retryTransientFailure: true)
            check(SyntheticAuth.attempts == 1 && !revoked.canRetrySessionRestore,
                  "permanent credential rejection does not retry automatically")

            SyntheticAuth.reset(.busy)
            let busy = CloudAccountStore()
            await busy.restoreIfPossible()
            check(busy.canRetrySessionRestore, "temporary authentication service failure is eligible for the next tick")
            SyntheticAuth.reset(.certificateFailure)
            let untrusted = CloudAccountStore()
            await untrusted.restoreIfPossible()
            check(!untrusted.canRetrySessionRestore, "certificate failure is not treated as a transient reconnect")

            SyntheticAuth.reset(.online)
            SyntheticAuth.hasToken = false
            let empty = CloudAccountStore()
            await empty.restoreIfPossible()
            await empty.restoreIfPossible(retryTransientFailure: true)
            check(SyntheticAuth.attempts == 0 && empty.state == .signedOut && !empty.canRetrySessionRestore,
                  "missing refresh token never starts a login request")

            SyntheticAuth.reset(.holding)
            let shared = CloudAccountStore()
            let first = Task { await shared.restoreIfPossible() }
            try await waitUntil { SyntheticAuth.release != nil }
            let second = Task { await shared.restoreIfPossible(retryTransientFailure: true) }
            await Task.yield()
            check(SyntheticAuth.attempts == 1, "overlapping restoration requests share a single request")
            shared.signOut()
            SyntheticAuth.release?.resume()
            await first.value
            await second.value
            check(shared.state == .signedOut && SyntheticAuth.saves == 0,
                  "late restore response cannot persist credentials or log in after sign-out")

            SyntheticAuth.reset(.offline)
            let disabled = CloudAccountStore()
            await disabled.restoreIfPossible()
            settings.disableAll()
            settings.setContext(availability: .ready, ownerUID: nil)
            check(!settings.sessionRecoveryEnabled, "disabling sync persists the recovery opt-out even while signed out")
            var recoveryCalls = 0
            let disabledCoordinator = AutomaticSyncCoordinator(defaults: defaults,
                timing: .init(periodic: 0.03), journal: journal)
            disabledCoordinator.configure(context: { .init(scope: "disabled", enabled: false) }, prepare: {},
                canRecoverSession: { settings.sessionRecoveryEnabled && disabled.canRetrySessionRestore },
                recoverSession: { recoveryCalls += 1; await disabled.restoreIfPossible(retryTransientFailure: true) },
                metadata: { _ in .completed }, logs: { _ in .completed })
            disabledCoordinator.setActive(true)
            SyntheticAuth.mode = .online
            try await Task.sleep(for: .milliseconds(110))
            disabledCoordinator.setActive(false)
            check(recoveryCalls == 0 && SyntheticAuth.attempts == 1, "disabled sync prevents recovery on multiple periodic ticks")
            settings.setContext(availability: .ready, ownerUID: "different-owner")
            check(!settings.sessionRecoveryEnabled, "another account does not inherit the previous account's sync intent")

            func retryStore() -> CloudAccountStore {
                CloudAccountStore(openAuthorizationURL: { _ in SyntheticAuth.browserOpens += 1; return true })
            }
            SyntheticAuth.reset(.restricted)
            let invited = retryStore()
            invited.signIn()
            try await waitUntil { invited.canRetryGoogleSignIn }
            check(SyntheticAuth.browserOpens == 1 && SyntheticAuth.googleExchanges == 1 && SyntheticAuth.saves == 0,
                  "closed admission retains only memory retry eligibility and saves no session")
            invited.retrySignIn()
            try await waitUntil { invited.canRetryGoogleSignIn && SyntheticAuth.attempts == 2 }
            check(SyntheticAuth.browserOpens == 1 && SyntheticAuth.googleExchanges == 1,
                  "repeated admission failure retries Firebase without reopening OAuth")
            SyntheticAuth.mode = .online
            invited.retrySignIn()
            invited.retrySignIn()
            try await waitUntil { invited.state.signedInAccount != nil }
            check(SyntheticAuth.attempts == 3 && SyntheticAuth.saves == 1 && !invited.canRetryGoogleSignIn,
                  "admission retry is single-flight and success clears its pending credential")

            SyntheticAuth.reset(.restricted)
            let switched = retryStore()
            switched.signIn()
            try await waitUntil { switched.canRetryGoogleSignIn }
            SyntheticAuth.mode = .online
            switched.signInWithDifferentAccount()
            try await waitUntil { switched.state.signedInAccount != nil }
            check(SyntheticAuth.browserOpens == 2 && SyntheticAuth.googleExchanges == 2,
                  "explicit account switch discards retry and performs a fresh OAuth exchange")

            SyntheticAuth.reset(.restricted)
            let cancelled = retryStore()
            cancelled.signIn()
            try await waitUntil { cancelled.canRetryGoogleSignIn }
            SyntheticAuth.mode = .holding
            cancelled.retrySignIn()
            try await waitUntil { SyntheticAuth.release != nil }
            cancelled.cancelSignIn()
            SyntheticAuth.release?.resume()
            try await Task.sleep(for: .milliseconds(15))
            check(cancelled.state == .signedOut && SyntheticAuth.saves == 0 && !cancelled.canRetryGoogleSignIn,
                  "late retry success cannot persist after cancellation")

            SyntheticAuth.reset(.restricted)
            let generations = retryStore()
            generations.signIn()
            try await waitUntil { generations.canRetryGoogleSignIn }
            SyntheticAuth.mode = .holding
            generations.retrySignIn()
            try await waitUntil { SyntheticAuth.release != nil }
            let oldRelease = SyntheticAuth.release
            SyntheticAuth.release = nil
            generations.signInWithDifferentAccount()
            try await waitUntil { SyntheticAuth.release != nil }
            let newRelease = SyntheticAuth.release
            oldRelease?.resume()
            try await Task.sleep(for: .milliseconds(15))
            generations.retrySignIn()
            check(SyntheticAuth.attempts == 3 && SyntheticAuth.saves == 0,
                  "old cancelled completion cannot clear a newer in-flight login task")
            newRelease?.resume()
            try await waitUntil { generations.state.signedInAccount != nil }
            check(SyntheticAuth.saves == 1 && !generations.canRetryGoogleSignIn,
                  "only the latest account generation may persist a session")

            SyntheticAuth.reset(.restricted)
            let loggedOut = retryStore()
            loggedOut.signIn()
            try await waitUntil { loggedOut.canRetryGoogleSignIn }
            loggedOut.signOut()
            check(!loggedOut.canRetryGoogleSignIn && loggedOut.state == .signedOut,
                  "sign-out immediately clears Google retry eligibility")

            SyntheticAuth.reset(.offline)
            let networkError = retryStore()
            networkError.signIn()
            try await waitUntil { if case .failed = networkError.state { return true }; return false }
            check(!networkError.canRetryGoogleSignIn && SyntheticAuth.saves == 0,
                  "an unrelated error does not retain Google retry credentials")

            SyntheticAuth.reset(.restricted)
            SyntheticAuth.credentialLifetime = GoogleSignInRetryCredential.expiryMargin + 0.2
            let expired = retryStore()
            expired.signIn()
            try await waitUntil { expired.canRetryGoogleSignIn }
            try await waitUntil { !expired.canRetryGoogleSignIn }
            SyntheticAuth.credentialLifetime = 3600
            SyntheticAuth.mode = .online
            expired.retrySignIn()
            try await waitUntil { expired.state.signedInAccount != nil }
            check(SyntheticAuth.browserOpens == 2 && SyntheticAuth.googleExchanges == 2,
                  "expiry clears the credential and the next retry starts normal OAuth")
            check(!retryStore().canRetryGoogleSignIn, "a newly initialized store never restores a pending Google credential")
        } catch {
            failed += 1
            print("FAIL: synthetic recovery harness \((error as NSError).code)")
        }
        await journal.flush()
        print("\(passed) cloud account recovery tests passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
