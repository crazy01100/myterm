import Foundation

struct HostConnectionRecencyIndex: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    private(set) var lastConnectedAtByHostID: [String: Date] = [:]

    init() { }

    func lastConnectedAt(for hostID: HostProfile.ID) -> Date? {
        lastConnectedAtByHostID[hostID.uuidString]
    }

    mutating func recordSuccessfulConnection(
        for hostID: HostProfile.ID,
        at date: Date = .now
    ) {
        lastConnectedAtByHostID[hostID.uuidString] = date
    }

    mutating func remove(hostID: HostProfile.ID) {
        lastConnectedAtByHostID.removeValue(forKey: hostID.uuidString)
    }

    mutating func prune(validHostIDs: Set<HostProfile.ID>) {
        lastConnectedAtByHostID = lastConnectedAtByHostID.filter { key, _ in
            guard let hostID = UUID(uuidString: key) else { return false }
            return validHostIDs.contains(hostID)
        }
    }

    func sortingByMostRecentConnection(
        _ candidates: [HostProfile],
        canonicalHosts: [HostProfile]
    ) -> [HostProfile] {
        let canonicalRanks = Dictionary(
            uniqueKeysWithValues: canonicalHosts.enumerated().map { ($0.element.id, $0.offset) }
        )

        return candidates.sorted { first, second in
            let firstDate = lastConnectedAt(for: first.id)
            let secondDate = lastConnectedAt(for: second.id)

            switch (firstDate, secondDate) {
            case let (firstDate?, secondDate?) where firstDate != secondDate:
                return firstDate > secondDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let firstRank = canonicalRanks[first.id] ?? Int.max
                let secondRank = canonicalRanks[second.id] ?? Int.max
                if firstRank != secondRank {
                    return firstRank < secondRank
                }
                return first.id.uuidString < second.id.uuidString
            }
        }
    }
}
