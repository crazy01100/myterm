import Darwin
import Foundation

enum LoopbackOAuthError: LocalizedError {
    case failedToStart(String)
    case stoppedBeforeReady
    case invalidHTTPRequest
    case requestTooLarge
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failedToStart(let detail): "無法啟動 Google 登入的本機回呼（\(detail)）。"
        case .stoppedBeforeReady: "Google 登入的本機回呼已停止。"
        case .invalidHTTPRequest: "收到格式不正確的 Google 登入回呼。"
        case .requestTooLarge: "Google 登入回呼超過安全大小限制。"
        case .timedOut: "等待 Google 登入逾時，請重新嘗試。"
        }
    }
}

/// A one-shot HTTP listener bound explicitly to IPv4 loopback. A local BSD
/// socket is used here so the OAuth callback never listens on Wi-Fi/Ethernet.
final class LoopbackOAuthListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tw.local.MySSHClient.oauth-loopback")
    private let expectedState: String
    private let port: UInt16
    private var listenFD: Int32
    private var clientFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var requestData = Data()
    private var callbackContinuation: CheckedContinuation<OAuthCallback, Error>?
    private var pendingResult: Result<OAuthCallback, Error>?
    private var didFinish = false

    private init(listenFD: Int32, port: UInt16, expectedState: String) {
        self.listenFD = listenFD
        self.port = port
        self.expectedState = expectedState
    }

    static func start(expectedState: String) async throws -> Self {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw LoopbackOAuthError.failedToStart(systemError())
        }

        var reuse: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(fileDescriptor)
            throw LoopbackOAuthError.failedToStart("無法解析 127.0.0.1")
        }

        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else {
            let detail = systemError()
            close(fileDescriptor)
            throw LoopbackOAuthError.failedToStart(detail)
        }
        guard Darwin.listen(fileDescriptor, 1) == 0 else {
            let detail = systemError()
            close(fileDescriptor)
            throw LoopbackOAuthError.failedToStart(detail)
        }

        var actualAddress = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &actualAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fileDescriptor, $0, &actualLength)
            }
        }
        guard nameStatus == 0 else {
            let detail = systemError()
            close(fileDescriptor)
            throw LoopbackOAuthError.failedToStart(detail)
        }

        let server = Self(
            listenFD: fileDescriptor,
            port: UInt16(bigEndian: actualAddress.sin_port),
            expectedState: expectedState
        )
        server.startAccepting()
        return server
    }

    var redirectURI: URL? {
        URL(string: "http://127.0.0.1:\(port)\(OAuthCallback.path)")
    }

    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> OAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: LoopbackOAuthError.stoppedBeforeReady)
                        return
                    }
                    if let result = self.pendingResult {
                        self.pendingResult = nil
                        continuation.resume(with: result)
                        return
                    }
                    guard !self.didFinish else {
                        continuation.resume(throwing: LoopbackOAuthError.stoppedBeforeReady)
                        return
                    }
                    self.callbackContinuation = continuation
                    self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
                        self?.finish(.failure(LoopbackOAuthError.timedOut))
                    }
                }
            }
        } onCancel: {
            queue.async { [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(.failure(CancellationError())) }
    }

    private func startAccepting() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            close(self.listenFD)
            self.listenFD = -1
        }
        acceptSource = source
        source.resume()
    }

    private func acceptConnection() {
        guard !didFinish, clientFD < 0 else { return }
        var peer = sockaddr_in()
        var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let accepted = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenFD, $0, &peerLength)
            }
        }
        guard accepted >= 0 else {
            finish(.failure(LoopbackOAuthError.failedToStart(Self.systemError())))
            return
        }
        guard peer.sin_family == sa_family_t(AF_INET),
              peer.sin_addr.s_addr == in_addr_t(bigEndian: INADDR_LOOPBACK) else {
            close(accepted)
            return
        }

        clientFD = accepted
        acceptSource?.cancel()
        acceptSource = nil
        let source = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: queue)
        source.setEventHandler { [weak self] in self?.readRequest() }
        source.setCancelHandler { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            close(self.clientFD)
            self.clientFD = -1
        }
        clientSource = source
        source.resume()
    }

    private func readRequest() {
        guard clientFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(clientFD, &buffer, buffer.count)
        if count > 0 {
            requestData.append(contentsOf: buffer.prefix(count))
            if requestData.count > 32_768 {
                sendResponse(success: false)
                finish(.failure(LoopbackOAuthError.requestTooLarge))
            } else if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                processRequest()
            }
        } else if count == 0 {
            sendResponse(success: false)
            finish(.failure(LoopbackOAuthError.invalidHTTPRequest))
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            sendResponse(success: false)
            finish(.failure(LoopbackOAuthError.invalidHTTPRequest))
        }
    }

    private func processRequest() {
        guard let request = String(data: requestData, encoding: .utf8) else {
            sendResponse(success: false)
            finish(.failure(LoopbackOAuthError.invalidHTTPRequest))
            return
        }
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first,
              let hostHeader = lines.first(where: { $0.lowercased().hasPrefix("host:") }) else {
            sendResponse(success: false)
            finish(.failure(LoopbackOAuthError.invalidHTTPRequest))
            return
        }
        let receivedHost = hostHeader.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard receivedHost.caseInsensitiveCompare("127.0.0.1:\(port)") == .orderedSame else {
            sendResponse(success: false)
            finish(.failure(LoopbackOAuthError.invalidHTTPRequest))
            return
        }
        let fields = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3, fields[0] == "GET", fields[2].hasPrefix("HTTP/1.") else {
            sendResponse(success: false)
            finish(.failure(LoopbackOAuthError.invalidHTTPRequest))
            return
        }

        do {
            let callback = try OAuthCallback.parse(requestTarget: String(fields[1]))
            guard OAuthConstantTime.equal(callback.state, expectedState) else {
                throw OAuthSecurityError.stateMismatch
            }
            sendResponse(success: true)
            finish(.success(callback))
        } catch {
            sendResponse(success: false)
            finish(.failure(error))
        }
    }

    private func sendResponse(success: Bool) {
        guard clientFD >= 0 else { return }
        let title = success ? "已收到 Google 回應" : "登入驗證失敗"
        let detail = success ? "請回到 MyTerm 查看登入結果。此頁可以關閉。" : "請關閉此頁，回到 MyTerm 後重新嘗試。"
        let body = """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>MyTerm</title></head><body style="font-family:-apple-system;margin:48px"><h1>\(title)</h1><p>\(detail)</p></body></html>
        """
        let bodyData = Data(body.utf8)
        let status = success ? "200 OK" : "400 Bad Request"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(bodyData)
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(clientFD, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        _ = shutdown(clientFD, SHUT_WR)
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        guard !didFinish else { return }
        didFinish = true
        acceptSource?.cancel()
        acceptSource = nil
        clientSource?.cancel()
        clientSource = nil
        let continuation = callbackContinuation
        callbackContinuation = nil
        if let continuation {
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    private static func systemError() -> String {
        String(cString: strerror(errno))
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
