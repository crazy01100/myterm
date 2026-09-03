import Foundation

enum TerminalWorkspaceSplitAxis: Equatable {
    case horizontal
    case vertical
}

enum TerminalWorkspaceDropPosition: String, CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom

    var splitAxis: TerminalWorkspaceSplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }

    var insertsBeforeTarget: Bool {
        switch self {
        case .left, .top: true
        case .right, .bottom: false
        }
    }
}

enum TerminalWorkspaceMutationError: LocalizedError, Equatable {
    case workspaceNotFound
    case cannotMergeSameWorkspace
    case sourceMustBeSinglePane
    case sourceMustBeSplit
    case targetAlreadyHasTwoPanes

    var errorDescription: String? {
        switch self {
        case .workspaceNotFound:
            "找不到要操作的工作區。"
        case .cannotMergeSameWorkspace:
            "不能把工作區拖放到自己。"
        case .sourceMustBeSinglePane:
            "分割工作區只能整體重新排序，不能再合併到其他工作區。"
        case .sourceMustBeSplit:
            "只有雙窗格工作區能把窗格拆回獨立分頁。"
        case .targetAlreadyHasTwoPanes:
            "每個工作區最多兩個連線。"
        }
    }
}

struct TerminalWorkspace: Identifiable, Equatable {
    let id: UUID
    fileprivate(set) var sessionIDs: [UUID]
    fileprivate(set) var splitAxis: TerminalWorkspaceSplitAxis?
    fileprivate(set) var activeSessionID: UUID
    fileprivate(set) var splitRatio: Double

    init(id: UUID = UUID(), sessionID: UUID) {
        self.id = id
        sessionIDs = [sessionID]
        splitAxis = nil
        activeSessionID = sessionID
        splitRatio = 0.5
    }

    var isSplit: Bool { sessionIDs.count == 2 }

    func contains(sessionID: UUID) -> Bool {
        sessionIDs.contains(sessionID)
    }
}

struct TerminalWorkspaceCollection: Equatable {
    private(set) var workspaces: [TerminalWorkspace] = []
    private(set) var selectedWorkspaceID: TerminalWorkspace.ID?

    var selectedWorkspace: TerminalWorkspace? {
        workspace(id: selectedWorkspaceID)
    }

    var selectedSessionID: UUID? {
        selectedWorkspace?.activeSessionID
    }

    func workspace(id: TerminalWorkspace.ID?) -> TerminalWorkspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func workspace(containing sessionID: UUID) -> TerminalWorkspace? {
        workspaces.first { $0.contains(sessionID: sessionID) }
    }

    @discardableResult
    mutating func add(sessionID: UUID) -> TerminalWorkspace.ID {
        let workspace = TerminalWorkspace(sessionID: sessionID)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        return workspace.id
    }

    mutating func showLibrary() {
        selectedWorkspaceID = nil
    }

    @discardableResult
    mutating func selectWorkspace(id: TerminalWorkspace.ID?) -> Bool {
        guard let id else {
            selectedWorkspaceID = nil
            return true
        }
        guard workspaces.contains(where: { $0.id == id }) else { return false }
        selectedWorkspaceID = id
        return true
    }

    @discardableResult
    mutating func activate(sessionID: UUID) -> Bool {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.contains(sessionID: sessionID) }) else {
            return false
        }
        workspaces[workspaceIndex].activeSessionID = sessionID
        selectedWorkspaceID = workspaces[workspaceIndex].id
        return true
    }

    @discardableResult
    mutating func selectWorkspace(at index: Int) -> Bool {
        guard workspaces.indices.contains(index) else { return false }
        selectedWorkspaceID = workspaces[index].id
        return true
    }

    @discardableResult
    mutating func selectAdjacentWorkspace(offset: Int) -> Bool {
        guard !workspaces.isEmpty else { return false }
        guard let selectedWorkspaceID,
              let currentIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else {
            self.selectedWorkspaceID = offset < 0 ? workspaces.last?.id : workspaces.first?.id
            return true
        }
        let nextIndex = (currentIndex + offset % workspaces.count + workspaces.count) % workspaces.count
        self.selectedWorkspaceID = workspaces[nextIndex].id
        return true
    }

    func preferredMergeTargetID(for sourceWorkspaceID: TerminalWorkspace.ID) -> TerminalWorkspace.ID? {
        guard let sourceIndex = workspaces.firstIndex(where: { $0.id == sourceWorkspaceID }) else {
            return nil
        }
        if sourceIndex > 0 {
            return workspaces[sourceIndex - 1].id
        }
        let followingIndex = sourceIndex + 1
        guard workspaces.indices.contains(followingIndex) else { return nil }
        return workspaces[followingIndex].id
    }

    @discardableResult
    mutating func moveWorkspace(id: TerminalWorkspace.ID, toInsertionIndex insertionIndex: Int) -> Bool {
        guard let sourceIndex = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        let workspace = workspaces.remove(at: sourceIndex)
        var destinationIndex = min(max(0, insertionIndex), workspaces.count + 1)
        if sourceIndex < destinationIndex { destinationIndex -= 1 }
        destinationIndex = min(max(0, destinationIndex), workspaces.count)
        workspaces.insert(workspace, at: destinationIndex)
        return destinationIndex != sourceIndex
    }

    @discardableResult
    mutating func merge(
        sourceWorkspaceID: TerminalWorkspace.ID,
        targetWorkspaceID: TerminalWorkspace.ID,
        position: TerminalWorkspaceDropPosition
    ) throws -> TerminalWorkspace.ID {
        guard sourceWorkspaceID != targetWorkspaceID else {
            throw TerminalWorkspaceMutationError.cannotMergeSameWorkspace
        }
        guard let sourceIndex = workspaces.firstIndex(where: { $0.id == sourceWorkspaceID }),
              let targetIndex = workspaces.firstIndex(where: { $0.id == targetWorkspaceID }) else {
            throw TerminalWorkspaceMutationError.workspaceNotFound
        }

        let source = workspaces[sourceIndex]
        var target = workspaces[targetIndex]
        guard source.sessionIDs.count == 1 else {
            throw TerminalWorkspaceMutationError.sourceMustBeSinglePane
        }
        guard target.sessionIDs.count == 1 else {
            throw TerminalWorkspaceMutationError.targetAlreadyHasTwoPanes
        }

        let sourceSessionID = source.sessionIDs[0]
        let targetSessionID = target.sessionIDs[0]
        target.sessionIDs = position.insertsBeforeTarget
            ? [sourceSessionID, targetSessionID]
            : [targetSessionID, sourceSessionID]
        target.splitAxis = position.splitAxis
        target.activeSessionID = sourceSessionID
        target.splitRatio = 0.5

        workspaces[targetIndex] = target
        workspaces.remove(at: sourceIndex)
        selectedWorkspaceID = target.id
        return target.id
    }

    @discardableResult
    mutating func detach(
        sessionID: UUID,
        toInsertionIndex insertionIndex: Int
    ) throws -> TerminalWorkspace.ID {
        guard let sourceIndex = workspaces.firstIndex(where: { $0.contains(sessionID: sessionID) }) else {
            throw TerminalWorkspaceMutationError.workspaceNotFound
        }
        guard workspaces[sourceIndex].isSplit else {
            throw TerminalWorkspaceMutationError.sourceMustBeSplit
        }

        workspaces[sourceIndex].sessionIDs.removeAll { $0 == sessionID }
        workspaces[sourceIndex].activeSessionID = workspaces[sourceIndex].sessionIDs[0]
        workspaces[sourceIndex].splitAxis = nil
        workspaces[sourceIndex].splitRatio = 0.5

        let detachedWorkspace = TerminalWorkspace(sessionID: sessionID)
        let destinationIndex = min(max(0, insertionIndex), workspaces.count)
        workspaces.insert(detachedWorkspace, at: destinationIndex)
        selectedWorkspaceID = detachedWorkspace.id
        return detachedWorkspace.id
    }

    @discardableResult
    mutating func setSplitAxis(
        _ splitAxis: TerminalWorkspaceSplitAxis,
        for workspaceID: TerminalWorkspace.ID
    ) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].isSplit else { return false }
        workspaces[index].splitAxis = splitAxis
        return true
    }

    @discardableResult
    mutating func toggleSplitAxis(for workspaceID: TerminalWorkspace.ID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let splitAxis = workspaces[index].splitAxis,
              workspaces[index].isSplit else { return false }
        workspaces[index].splitAxis = splitAxis == .horizontal ? .vertical : .horizontal
        return true
    }

    @discardableResult
    mutating func setSplitRatio(_ ratio: Double, for workspaceID: TerminalWorkspace.ID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].isSplit else { return false }
        workspaces[index].splitRatio = min(max(ratio, 0.25), 0.75)
        return true
    }

    @discardableResult
    mutating func focusOtherPane(in workspaceID: TerminalWorkspace.ID? = nil) -> Bool {
        let targetID = workspaceID ?? selectedWorkspaceID
        guard let index = workspaces.firstIndex(where: { $0.id == targetID }),
              workspaces[index].sessionIDs.count == 2 else { return false }
        let sessions = workspaces[index].sessionIDs
        workspaces[index].activeSessionID = sessions[0] == workspaces[index].activeSessionID
            ? sessions[1]
            : sessions[0]
        selectedWorkspaceID = workspaces[index].id
        return true
    }

    @discardableResult
    mutating func close(sessionID: UUID) -> Bool {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.contains(sessionID: sessionID) }) else {
            return false
        }

        if workspaces[workspaceIndex].sessionIDs.count == 2 {
            workspaces[workspaceIndex].sessionIDs.removeAll { $0 == sessionID }
            workspaces[workspaceIndex].activeSessionID = workspaces[workspaceIndex].sessionIDs[0]
            workspaces[workspaceIndex].splitAxis = nil
            workspaces[workspaceIndex].splitRatio = 0.5
            return true
        }

        let removedWorkspaceID = workspaces[workspaceIndex].id
        workspaces.remove(at: workspaceIndex)
        if selectedWorkspaceID == removedWorkspaceID {
            selectedWorkspaceID = workspaces.isEmpty
                ? nil
                : workspaces[min(workspaceIndex, workspaces.count - 1)].id
        }
        return true
    }
}
