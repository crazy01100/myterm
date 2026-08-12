import Foundation

enum SSHConnectionPhase: String, Equatable {
    case preparing
    case connecting
    case securing
    case authenticating
    case connected
    case failed

    var title: String {
        switch self {
        case .preparing: "準備連線"
        case .connecting: "正在連線"
        case .securing: "建立安全通道"
        case .authenticating: "驗證登入身分"
        case .connected: "連線完成"
        case .failed: "連線失敗"
        }
    }
}

enum SSHConnectionFailureKind: String, Equatable {
    case addressResolution
    case timeout
    case refused
    case unreachable
    case authenticationRejected
    case hostKeyVerification
    case keyExchangeAlgorithm
    case hostKeyAlgorithm
    case cipherAlgorithm
    case privateKeyUnavailable
    case agentUnavailable
    case remoteClosed
    case unknown

    var title: String {
        switch self {
        case .addressResolution: "找不到主機位址"
        case .timeout: "連線逾時"
        case .refused: "主機拒絕連線"
        case .unreachable: "無法到達主機"
        case .authenticationRejected: "登入驗證失敗"
        case .hostKeyVerification: "主機身分驗證失敗"
        case .keyExchangeAlgorithm: "金鑰交換演算法不相容"
        case .hostKeyAlgorithm: "主機金鑰演算法不相容"
        case .cipherAlgorithm: "加密演算法不相容"
        case .privateKeyUnavailable: "無法使用私鑰"
        case .agentUnavailable: "無法使用 SSH Agent"
        case .remoteClosed: "遠端主機中斷連線"
        case .unknown: "SSH 連線未完成"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .addressResolution:
            "請檢查主機名稱是否正確，以及目前網路或 DNS 設定。"
        case .timeout:
            "請檢查 IP、連接埠、防火牆及 VPN／內部網路是否可用。"
        case .refused:
            "請確認 SSH 服務已啟動，且連接埠設定正確。"
        case .unreachable:
            "請檢查網路、路由、VPN 或主機是否在線。"
        case .authenticationRejected:
            "請檢查使用者名稱、密碼、私鑰或主機允許的驗證方式。"
        case .hostKeyVerification:
            "請先核對主機指紋；不要在未確認主機身分前移除信任記錄。"
        case .keyExchangeAlgorithm, .hostKeyAlgorithm, .cipherAlgorithm:
            "請在主機設定中檢查演算法模式；只為可信任的舊主機啟用相容設定。"
        case .privateKeyUnavailable:
            "請檢查私鑰檔案是否存在、格式正確且目前帳號可讀取。"
        case .agentUnavailable:
            "請確認 SSH Agent 正在執行，且已載入可用的登入身分。"
        case .remoteClosed:
            "請檢查伺服器端 SSH 服務、存取政策或連線限制。"
        case .unknown:
            "請檢查主機連線設定，或重試後查看完整的連線階段。"
        }
    }
}

struct SSHConnectionDiagnosticEvent: Equatable {
    let phase: SSHConnectionPhase
    let message: String
    let technicalLine: String?

    init(
        phase: SSHConnectionPhase,
        message: String,
        technicalLine: String? = nil
    ) {
        self.phase = phase
        self.message = message
        self.technicalLine = technicalLine
    }
}

struct SSHConnectionLogUpdate: Equatable {
    var events: [SSHConnectionDiagnosticEvent] = []
    var technicalLines: [String] = []
    var authenticatedMethod: String?
    var failure: SSHConnectionFailureKind?
}

/// Converts OpenSSH's private verbose log into both a small structured event
/// stream and an allow-listed user-facing transcript. Verbose `debugN:` lines
/// remain an internal parsing source; the transcript only keeps OpenSSH's real
/// non-debug errors after removing local paths and other sensitive details.
struct SSHConnectionLogParser {
    private var partialLine = ""
    private var emittedMessages = Set<String>()
    private(set) var latestFailure: SSHConnectionFailureKind?

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> SSHConnectionLogUpdate {
        guard !bytes.isEmpty else { return SSHConnectionLogUpdate() }
        partialLine += String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if partialLine.count > 65_536 {
            partialLine = String(partialLine.suffix(65_536))
        }

        var lines = partialLine.split(separator: "\n", omittingEmptySubsequences: false)
        partialLine = lines.popLast().map(String.init) ?? ""
        return parse(lines.map(String.init))
    }

    mutating func finish() -> SSHConnectionLogUpdate {
        guard !partialLine.isEmpty else { return SSHConnectionLogUpdate(failure: latestFailure) }
        let line = partialLine
        partialLine.removeAll(keepingCapacity: false)
        return parse([line])
    }

    static func technicalTranscript(from data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let maximumSnapshotBytes = 65_536
        let bytes: Data
        if data.count > maximumSnapshotBytes {
            bytes = Data(data.suffix(maximumSnapshotBytes))
        } else {
            bytes = data
        }

        var parser = SSHConnectionLogParser()
        var transcript = parser.consume(Array(bytes)[...]).technicalLines
        transcript.append(contentsOf: parser.finish().technicalLines)
        return transcript
    }

    /// Final presentation boundary shared by the UI and clipboard report.
    /// Keep this defensive filter even though the parser already excludes
    /// verbose lines, so no alternate transcript source can expose them.
    static func userFacingTechnicalLines(from lines: [String]) -> [String] {
        lines
            .flatMap { line in
                line.split(whereSeparator: \.isNewline).map(String.init)
            }
            .filter { !isVerboseDebugLine($0.lowercased()) }
    }

    private mutating func parse(_ lines: [String]) -> SSHConnectionLogUpdate {
        var update = SSHConnectionLogUpdate()
        for line in lines where !line.isEmpty {
            let lowercased = line.lowercased()
            let technicalLine = sanitizedTechnicalLine(line, lowercased: lowercased)

            if let technicalLine {
                update.technicalLines.append(technicalLine)
            }

            if let failure = classifyFailure(lowercased) {
                latestFailure = failure
                update.failure = failure
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .failed,
                        message: failure.title,
                        technicalLine: technicalLine ?? redactedTechnicalLine(line)
                    ),
                    to: &update.events
                )
                continue
            }

            if lowercased.contains("authenticated to ") {
                update.authenticatedMethod = authenticationMethod(in: line)
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .connected,
                        message: "SSH 驗證成功，正在開啟終端工作階段。",
                        technicalLine: technicalLine
                    ),
                    to: &update.events
                )
            } else if lowercased.contains("authenticating to ") {
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .authenticating,
                        message: "安全通道已建立，正在驗證登入身分。",
                        technicalLine: technicalLine
                    ),
                    to: &update.events
                )
            } else if lowercased.contains("authentications that can continue") {
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .authenticating,
                        message: "伺服器正在要求登入驗證。",
                        technicalLine: technicalLine
                    ),
                    to: &update.events
                )
            } else if lowercased.contains("offering public key") {
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .authenticating,
                        message: "正在嘗試私鑰驗證。",
                        technicalLine: technicalLine
                    ),
                    to: &update.events
                )
            } else if lowercased.contains("connection established") {
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .securing,
                        message: "網路連線已建立，正在協商 SSH 安全通道。",
                        technicalLine: technicalLine
                    ),
                    to: &update.events
                )
            } else if lowercased.contains("remote protocol version") {
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .securing,
                        message: "已收到遠端 SSH 協定資訊。",
                        technicalLine: technicalLine
                    ),
                    to: &update.events
                )
            } else if lowercased.contains("connecting to ") {
                appendUnique(
                    SSHConnectionDiagnosticEvent(
                        phase: .connecting,
                        message: "正在連線至主機與指定連接埠。",
                        technicalLine: technicalLine
                    ),
                    to: &update.events
                )
            }
        }
        if update.failure == nil { update.failure = latestFailure }
        return update
    }

    private func sanitizedTechnicalLine(_ line: String, lowercased: String) -> String? {
        guard !Self.isVerboseDebugLine(lowercased) else { return nil }

        let excludedFragments = [
            "reading configuration data",
            "including file",
            "expanded userknownhostsfile",
            "ssh_get_authentication_socket",
            "identityagent",
            "ssh_auth_sock"
        ]
        guard !excludedFragments.contains(where: lowercased.contains) else { return nil }

        let includedFragments = [
            "connecting to ",
            "connection established",
            "local version string",
            "remote protocol version",
            "authenticating to ",
            "server host key:",
            "host key fingerprint",
            "kex: algorithm:",
            "kex: host key algorithm:",
            "kex: server->client cipher:",
            "kex: client->server cipher:",
            "authentications that can continue",
            "next authentication method",
            "identity file",
            "offering public key",
            "server accepts key",
            "trying private key",
            "will attempt key",
            "authenticated to ",
            "could not resolve hostname",
            "operation timed out",
            "connection timed out",
            "connection refused",
            "no route to host",
            "network is unreachable",
            "remote host identification has changed",
            "host key verification failed",
            "no matching key exchange method found",
            "no matching host key type found",
            "no matching cipher found",
            "could not open a connection to your authentication agent",
            "sign_and_send_pubkey",
            "load key",
            "permission denied",
            "connection closed by",
            "connection reset by",
            "kex_exchange_identification",
            "broken pipe"
        ]
        guard includedFragments.contains(where: lowercased.contains) else { return nil }

        return redactedTechnicalLine(line)
    }

    private static func isVerboseDebugLine(_ lowercased: String) -> Bool {
        guard lowercased.hasPrefix("debug") else { return false }
        let suffix = lowercased.dropFirst("debug".count)
        guard let colonIndex = suffix.firstIndex(of: ":") else { return false }
        let level = suffix[..<colonIndex]
        return !level.isEmpty && level.allSatisfy(\.isNumber)
    }

    private func redactedTechnicalLine(_ line: String) -> String {
        var sanitized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathPatterns = [
            #"(?:/Users|/home|/private|/var|/tmp|/Volumes|/Library|/System|/Applications|/opt|/usr/local|/etc)/[^\s\"']+"#,
            #"~/.ssh/[^\s\"']+"#
        ]
        for pattern in pathPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = expression.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "<本機路徑>"
            )
        }
        if sanitized.count > 2_048 {
            sanitized = String(sanitized.prefix(2_045)) + "..."
        }
        return sanitized
    }

    private mutating func appendUnique(
        _ event: SSHConnectionDiagnosticEvent,
        to events: inout [SSHConnectionDiagnosticEvent]
    ) {
        let key = "\(event.phase.rawValue):\(event.message)"
        guard emittedMessages.insert(key).inserted else { return }
        events.append(event)
    }

    private func authenticationMethod(in line: String) -> String? {
        let pattern = #"using \"([^\"]+)\"\."#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
              ),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private func classifyFailure(_ line: String) -> SSHConnectionFailureKind? {
        if line.contains("could not resolve hostname") { return .addressResolution }
        if line.contains("operation timed out") || line.contains("connection timed out") { return .timeout }
        if line.contains("connection refused") { return .refused }
        if line.contains("no route to host") || line.contains("network is unreachable") { return .unreachable }
        if line.contains("remote host identification has changed")
            || line.contains("host key verification failed") { return .hostKeyVerification }
        if line.contains("no matching key exchange method found") { return .keyExchangeAlgorithm }
        if line.contains("no matching host key type found") { return .hostKeyAlgorithm }
        if line.contains("no matching cipher found") { return .cipherAlgorithm }
        if line.contains("could not open a connection to your authentication agent")
            || (line.contains("sign_and_send_pubkey") && line.contains("agent")) { return .agentUnavailable }
        if line.contains("load key") && (
            line.contains("invalid format")
                || line.contains("permission denied")
                || line.contains("no such file")
        ) { return .privateKeyUnavailable }
        if line.contains("permission denied (") { return .authenticationRejected }
        if line.contains("connection closed by")
            || line.contains("connection reset by")
            || line.contains("kex_exchange_identification")
            || line.contains("broken pipe") { return .remoteClosed }
        return nil
    }
}
