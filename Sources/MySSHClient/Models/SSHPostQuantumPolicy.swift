import Foundation

struct SSHClientCapabilities: Equatable, Sendable {
    let version: String
    let keyExchangeAlgorithms: Set<String>

    var postQuantumAlgorithms: [String] {
        SSHPostQuantumPolicy.recognizedAlgorithms.filter(keyExchangeAlgorithms.contains)
    }
}

enum SSHPostQuantumError: LocalizedError, Equatable {
    case customConflict
    case notRequired
    case capabilityUnavailable
    case noSupportedAlgorithm

    var errorDescription: String? {
        switch self {
        case .customConflict:
            "已有自訂演算法設定。請先自行調整，MyTerm 不會直接覆蓋。"
        case .notRequired:
            "目前設定不是僅允許後量子金鑰交換的清單。"
        case .capabilityUnavailable:
            "無法確認本機 SSH 的支援能力，尚未啟動要求後量子金鑰交換的連線。請重新檢查後再試。"
        case .noSupportedAlgorithm:
            "本機 SSH 不支援這台主機要求的後量子金鑰交換演算法，尚未啟動連線。"
        }
    }
}

/// Existing custom KEX fields are the sole persistent policy source.
/// Capability narrowing is applied to process arguments only, never synced.
enum SSHPostQuantumPolicy {
    static let recognizedAlgorithms = [
        "mlkem768x25519-sha256",
        "sntrup761x25519-sha512",
        "sntrup761x25519-sha512@openssh.com"
    ]

    static func requiredAlgorithms(for host: HostProfile) -> [String]? {
        guard host.algorithmMode == .custom else { return nil }
        let entries = host.customAlgorithms.keyExchangeAlgorithms
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !entries.isEmpty, entries.allSatisfy(recognizedAlgorithms.contains) else { return nil }
        // Keep preference order while excluding duplicates.
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }

    static func settingRequired(_ required: Bool, for original: HostProfile) throws -> HostProfile {
        let existing = requiredAlgorithms(for: original)
        var host = original
        if !required {
            guard existing != nil else { throw SSHPostQuantumError.notRequired }
            host.customAlgorithms.keyExchangeAlgorithms = ""
            return host
        }
        if existing != nil { return original }
        guard original.customAlgorithms.keyExchangeAlgorithms.isEmpty else {
            // Even inactive custom values belong to the user; do not erase them.
            throw SSHPostQuantumError.customConflict
        }
        switch host.algorithmMode {
        case .systemDefault, .rsaCompatibility:
            guard host.customAlgorithms == CustomAlgorithms() else {
                throw SSHPostQuantumError.customConflict
            }
            if host.algorithmMode == .rsaCompatibility {
                host.customAlgorithms.hostKeyAlgorithms = "+ssh-rsa"
                host.customAlgorithms.publicKeyAlgorithms = "+ssh-rsa"
            }
        case .custom:
            break
        }
        host.algorithmMode = .custom
        host.customAlgorithms.keyExchangeAlgorithms = recognizedAlgorithms.joined(separator: ",")
        return host
    }

    static func runtimeAlgorithms(for host: HostProfile, capabilities: SSHClientCapabilities?) throws -> [String]? {
        guard let required = requiredAlgorithms(for: host) else { return nil }
        guard let capabilities else { throw SSHPostQuantumError.capabilityUnavailable }
        let supported = required.filter(capabilities.keyExchangeAlgorithms.contains)
        guard !supported.isEmpty else { throw SSHPostQuantumError.noSupportedAlgorithm }
        return supported
    }
}
