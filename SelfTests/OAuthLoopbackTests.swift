import Foundation

@main
struct OAuthLoopbackTests {
    static func main() async {
        do {
            let state = "loopback-state"
            let server = try await LoopbackOAuthListener.start(expectedState: state)
            guard let redirectURI = server.redirectURI,
                  redirectURI.host == "127.0.0.1",
                  redirectURI.port != nil else {
                throw LoopbackOAuthError.failedToStart("缺少本機連接埠")
            }
            let callbackTask = Task { try await server.waitForCallback(timeout: .seconds(5)) }
            var components = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "code", value: "loopback-code"),
                URLQueryItem(name: "state", value: state)
            ]
            var request = URLRequest(url: components.url!)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw LoopbackOAuthError.invalidHTTPRequest
            }
            let callback = try await callbackTask.value
            guard callback.code == "loopback-code", callback.state == state else {
                throw OAuthSecurityError.invalidCallback
            }
            print("PASS: OAuth loopback binds to 127.0.0.1 and accepts the matching state")

            let rejectedServer = try await LoopbackOAuthListener.start(expectedState: "expected")
            guard let rejectedURI = rejectedServer.redirectURI else {
                throw LoopbackOAuthError.failedToStart("缺少拒絕測試連接埠")
            }
            let rejectedTask = Task { try await rejectedServer.waitForCallback(timeout: .seconds(5)) }
            var rejectedComponents = URLComponents(url: rejectedURI, resolvingAgainstBaseURL: false)!
            rejectedComponents.queryItems = [
                URLQueryItem(name: "code", value: "untrusted-code"),
                URLQueryItem(name: "state", value: "wrong")
            ]
            let (_, rejectedResponse) = try await URLSession.shared.data(from: rejectedComponents.url!)
            guard (rejectedResponse as? HTTPURLResponse)?.statusCode == 400 else {
                throw LoopbackOAuthError.invalidHTTPRequest
            }
            do {
                _ = try await rejectedTask.value
                throw OAuthSecurityError.stateMismatch
            } catch OAuthSecurityError.stateMismatch {
                print("PASS: OAuth loopback rejects a mismatched state")
            }
        } catch {
            fputs("FAIL: OAuth loopback integration: \(error)\n", stderr)
            exit(1)
        }
    }
}
