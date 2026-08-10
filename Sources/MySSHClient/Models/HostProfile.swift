import Foundation

enum AuthenticationMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey
    case sshAgent

    var id: Self { self }
    var title: String {
        switch self {
        case .password: "密碼"
        case .privateKey: "私鑰"
        case .sshAgent: "SSH Agent／SSH Config"
        }
    }
}

enum AlgorithmMode: String, Codable, CaseIterable, Identifiable {
    case systemDefault
    case rsaCompatibility
    case custom

    var id: Self { self }
    var title: String {
        switch self {
        case .systemDefault: "系統預設（推薦）"
        case .rsaCompatibility: "舊式 RSA 相容"
        case .custom: "自訂"
        }
    }
}

enum HostPlatform: String, Codable, CaseIterable, Identifiable {
    case ubuntu, debian, almaLinux, rockyLinux, centOS, redHat, fedora, amazonLinux
    case alpine, openSUSE, archLinux, macOS, freeBSD
    case cisco, juniper, arista, openWrt

    var id: Self { self }

    var title: String {
        switch self {
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .almaLinux: "AlmaLinux"
        case .rockyLinux: "Rocky Linux"
        case .centOS: "CentOS"
        case .redHat: "Red Hat"
        case .fedora: "Fedora"
        case .amazonLinux: "Amazon Linux"
        case .alpine: "Alpine Linux"
        case .openSUSE: "openSUSE"
        case .archLinux: "Arch Linux"
        case .macOS: "macOS"
        case .freeBSD: "FreeBSD"
        case .cisco: "Cisco"
        case .juniper: "Junos"
        case .arista: "Arista EOS"
        case .openWrt: "OpenWrt"
        }
    }
}

struct CustomAlgorithms: Codable, Hashable {
    var hostKeyAlgorithms = ""
    var publicKeyAlgorithms = ""
    var keyExchangeAlgorithms = ""
    var ciphers = ""
}

struct HostGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var parentID: HostGroup.ID?
    var createdAt = Date()

    init(id: UUID = UUID(), name: String = "", parentID: HostGroup.ID? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

struct HostProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var hostname = ""
    var port = 22
    var username = ""
    var groupID: HostGroup.ID?
    var notes = ""
    var authenticationMethod: AuthenticationMethod = .password
    var privateKeyPath = ""
    var algorithmMode: AlgorithmMode = .systemDefault
    var customAlgorithms = CustomAlgorithms()
    var detectedPlatform: HostPlatform?
    var createdAt = Date()
    var updatedAt = Date()

    /// Used only while decoding the 0.1 array format. It is deliberately not
    /// written by the 0.2 encoder.
    var legacyGroupName: String?

    init() { }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, groupID, group, notes
        case authenticationMethod, privateKeyPath, algorithmMode, customAlgorithms
        case detectedPlatform
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try values.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        legacyGroupName = try values.decodeIfPresent(String.self, forKey: .group)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        authenticationMethod = try values.decodeIfPresent(AuthenticationMethod.self, forKey: .authenticationMethod) ?? .password
        privateKeyPath = try values.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        algorithmMode = try values.decodeIfPresent(AlgorithmMode.self, forKey: .algorithmMode) ?? .systemDefault
        customAlgorithms = try values.decodeIfPresent(CustomAlgorithms.self, forKey: .customAlgorithms) ?? CustomAlgorithms()
        detectedPlatform = try values.decodeIfPresent(HostPlatform.self, forKey: .detectedPlatform)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(hostname, forKey: .hostname)
        try values.encode(port, forKey: .port)
        try values.encode(username, forKey: .username)
        try values.encodeIfPresent(groupID, forKey: .groupID)
        try values.encode(notes, forKey: .notes)
        try values.encode(authenticationMethod, forKey: .authenticationMethod)
        try values.encode(privateKeyPath, forKey: .privateKeyPath)
        try values.encode(algorithmMode, forKey: .algorithmMode)
        try values.encode(customAlgorithms, forKey: .customAlgorithms)
        try values.encodeIfPresent(detectedPlatform, forKey: .detectedPlatform)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

enum HostValidationError: LocalizedError, Equatable {
    case invalidHostname
    case invalidUsername
    case invalidPort
    case missingPrivateKey
    case invalidAlgorithm(field: String)

    var errorDescription: String? {
        switch self {
        case .invalidHostname: "主機位址格式不正確。"
        case .invalidUsername: "使用者名稱格式不正確。"
        case .invalidPort: "連接埠必須介於 1 到 65535。"
        case .missingPrivateKey: "請選擇私鑰檔案。"
        case .invalidAlgorithm(let field): "\(field) 含有不允許的字元。"
        }
    }
}

extension HostProfile {
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? hostname : trimmedName
    }

    var addressDescription: String {
        username.isEmpty ? "\(hostname):\(port)" : "\(username)@\(hostname):\(port)"
    }

    func validated() throws -> HostProfile {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.privateKeyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        result.legacyGroupName = nil
        result.updatedAt = .now

        let hostPattern = #"^(?=.{1,253}$)(?!-)(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:]+\])$"#
        guard result.hostname.range(of: hostPattern, options: .regularExpression) != nil else {
            throw HostValidationError.invalidHostname
        }
        let userPattern = #"^[A-Za-z0-9._-]{1,64}$"#
        guard result.username.isEmpty || result.username.range(of: userPattern, options: .regularExpression) != nil else {
            throw HostValidationError.invalidUsername
        }
        guard (1...65535).contains(result.port) else { throw HostValidationError.invalidPort }
        if result.authenticationMethod == .privateKey && result.privateKeyPath.isEmpty {
            throw HostValidationError.missingPrivateKey
        }
        if result.algorithmMode == .custom {
            let values = [
                ("Host Key Algorithms", result.customAlgorithms.hostKeyAlgorithms),
                ("Public Key Algorithms", result.customAlgorithms.publicKeyAlgorithms),
                ("Key Exchange Algorithms", result.customAlgorithms.keyExchangeAlgorithms),
                ("Ciphers", result.customAlgorithms.ciphers)
            ]
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._,+-^*!?")
            for (field, value) in values where !value.isEmpty {
                if value.rangeOfCharacter(from: allowed.inverted) != nil || value.count > 1024 {
                    throw HostValidationError.invalidAlgorithm(field: field)
                }
            }
        }
        return result
    }


    static func validatedUsername(_ value: String) throws -> String {
        let username = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[A-Za-z0-9._-]{1,64}$"#
        guard username.range(of: pattern, options: .regularExpression) != nil else {
            throw HostValidationError.invalidUsername
        }
        return username
    }
}
