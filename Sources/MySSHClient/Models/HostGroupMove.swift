import Foundation

enum HostGroupDropHitTesting {
    static func hostID(
        at point: CGPoint,
        hostFrames: [HostProfile.ID: CGRect]
    ) -> HostProfile.ID? {
        hostFrames.first { $0.value.contains(point) }?.key
    }

    static func groupID(
        at point: CGPoint,
        groupFrames: [HostGroup.ID: CGRect],
        excluding excludedGroupID: HostGroup.ID?
    ) -> HostGroup.ID? {
        groupFrames.first {
            $0.key != excludedGroupID && $0.value.contains(point)
        }?.key
    }
}

enum HostGroupMoveError: LocalizedError, Equatable {
    case missingHost
    case missingGroup

    var errorDescription: String? {
        switch self {
        case .missingHost: "找不到要移動的主機。"
        case .missingGroup: "找不到目標分類。"
        }
    }
}

enum HostGroupMoveMutation {
    static func applying(
        hostID: HostProfile.ID,
        targetGroupID: HostGroup.ID?,
        validGroupIDs: Set<HostGroup.ID>,
        to hosts: [HostProfile],
        at date: Date = .now
    ) throws -> [HostProfile]? {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) else {
            throw HostGroupMoveError.missingHost
        }
        if let targetGroupID, !validGroupIDs.contains(targetGroupID) {
            throw HostGroupMoveError.missingGroup
        }
        guard hosts[hostIndex].groupID != targetGroupID else { return nil }

        var updatedHosts = hosts
        updatedHosts[hostIndex].groupID = targetGroupID
        updatedHosts[hostIndex].updatedAt = date
        return updatedHosts
    }
}
