import Foundation

struct InventoryDocument: Codable {
    static let currentSchemaVersion = 3

    var schemaVersion = currentSchemaVersion
    var groups: [HostGroup] = []
    var hosts: [HostProfile] = []

    static func migrating(_ legacyHosts: [HostProfile]) -> InventoryDocument {
        var groupsByName: [String: HostGroup] = [:]
        var migratedHosts = legacyHosts

        for index in migratedHosts.indices {
            let legacyName = migratedHosts[index].legacyGroupName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !legacyName.isEmpty && legacyName != "未分類" {
                let key = legacyName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let group = groupsByName[key] ?? HostGroup(name: legacyName)
                groupsByName[key] = group
                migratedHosts[index].groupID = group.id
            }
            migratedHosts[index].legacyGroupName = nil
        }

        return InventoryDocument(
            groups: groupsByName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            hosts: migratedHosts
        )
    }
}
