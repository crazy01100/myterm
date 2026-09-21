import Foundation

enum QuickActionDestination: Hashable {
    case session(UUID)
    case host(UUID)
    case temporarySSH(QuickSSHRequest)
    case operation(QuickActionOperation)
}

enum QuickActionOperation: String, CaseIterable {
    case hosts, sftp, terminal, serial, knownHosts, logs, snippets

    var title: String {
        switch self {
        case .hosts: "返回所有主機"
        case .sftp: "開啟 SFTP"
        case .terminal: "開啟本機 Terminal"
        case .serial: "開啟 Serial 設定"
        case .knownHosts: "查看 Known Hosts"
        case .logs: "查看 Logs"
        case .snippets: "開啟常用指令庫"
        }
    }
    var keywords: String {
        switch self {
        case .hosts: "hosts 首頁 主機 群組"
        case .sftp: "sftp 檔案 傳輸 上傳 下載"
        case .terminal: "terminal local 本地 本機 終端"
        case .serial: "serial 串列 串口"
        case .knownHosts: "known hosts 指紋 信任"
        case .logs: "logs log 連線 紀錄 記錄 歷史"
        case .snippets: "snippet command 常用 指令庫 指令"
        }
    }
    var symbol: String {
        switch self {
        case .hosts: "server.rack"
        case .sftp: "folder"
        case .terminal: "terminal"
        case .serial: "cable.connector"
        case .knownHosts: "checkmark.shield"
        case .logs: "clock.arrow.circlepath"
        case .snippets: "curlybraces"
        }
    }
}

struct QuickActionItem: Identifiable, Equatable {
    enum Section: Int, CaseIterable {
        case sessions, hosts, temporary, operations
        var title: String {
            switch self {
            case .sessions: "已開啟"
            case .hosts: "主機"
            case .temporary: "臨時連線"
            case .operations: "操作"
            }
        }
    }
    let id: QuickActionDestination
    let section: Section
    let title: String
    let detail: String
    let hint: String
    let symbol: String
    let keywords: String
    var hostID: UUID?
    var endpoint: QuickSSHRequest? = nil
    var platform: HostPlatform? = nil

    static var operations: [Self] {
        QuickActionOperation.allCases.map {
            Self(id: .operation($0), section: .operations, title: $0.title,
                 detail: "", hint: "操作", symbol: $0.symbol, keywords: $0.keywords)
        }
    }
}

enum QuickActionSearch {
    /// Source order is the workspace order / HostStore recency order.
    static func results(_ items: [QuickActionItem], query: String) -> [QuickActionItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terms = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let request = QuickSSHRequest.parse(query)
        let openHosts = Set(items.filter { $0.section == .sessions }.compactMap(\.hostID))
        let matches = items.enumerated().compactMap { index, item -> (Int, QuickActionItem, Int)? in
            if item.section == .hosts, let id = item.hostID, openHosts.contains(id) { return nil }
            let haystack = "\(item.title) \(item.detail) \(item.keywords)".lowercased()
            if let request {
                guard item.endpoint == request else { return nil }
            } else {
                guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
            }
            let title = item.title.lowercased()
            let rank = normalized.isEmpty ? 2 : title == normalized ? 0 : title.hasPrefix(normalized) ? 1 : 2
            return (index, item, rank)
        }.sorted {
            if $0.1.section != $1.1.section { return $0.1.section.rawValue < $1.1.section.rawValue }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0 < $1.0
        }.map { $0.1 }
        if let request {
            return matches + [QuickActionItem(id: .temporarySSH(request), section: .temporary,
                title: "臨時連線：\(request.displayAddress)", detail: "不加入主機庫", hint: "連線",
                symbol: "terminal", keywords: "", endpoint: request)]
        }
        guard normalized.isEmpty else { return matches }
        var hostCount = 0
        return matches.filter { item in
            guard item.section == .hosts else { return true }
            hostCount += 1
            return hostCount <= 6
        }
    }
}
