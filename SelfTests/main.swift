import Foundation
import Security

private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        passed += 1
        print("PASS: \(name)")
    } else {
        failed += 1
        print("FAIL: \(name)")
    }
}

private func baseHost() -> HostProfile {
    var host = HostProfile()
    host.name = "Test"
    host.hostname = "192.0.2.10"
    host.username = "operator"
    return host
}

do {
    let start = Date(timeIntervalSince1970: 1_000)
    let connected = Date(timeIntervalSince1970: 1_005)
    let ended = Date(timeIntervalSince1970: 1_065)
    let sessionID = UUID()
    let recordID = UUID()
    var host = baseHost()
    host.name = "Audit Snapshot"
    host.detectedPlatform = .ubuntu

    var audit = ConnectionAuditIndex(maximumRecordCount: 5_000)
    let sourceDeviceID = UUID()
    let firstID = audit.begin(
        sessionID: sessionID,
        host: host,
        username: "other-user",
        at: start,
        sourceDeviceID: sourceDeviceID,
        sourceDeviceName: "Test Mac",
        recordID: recordID
    )
    let repeatedID = audit.begin(
        sessionID: sessionID,
        host: host,
        username: "other-user",
        at: start.addingTimeInterval(1)
    )
    check(firstID == recordID && repeatedID == recordID && audit.records.count == 1,
          "connection audit begin is idempotent for one terminal session")
    check(
        audit.records.first?.hostName == "Audit Snapshot" &&
            audit.records.first?.username == "other-user" &&
            audit.records.first?.sourceDeviceID == sourceDeviceID &&
            audit.records.first?.sourceDeviceName == "Test Mac" &&
            audit.records.first?.platform == .ubuntu,
        "connection audit stores immutable host and source-device snapshots without credentials"
    )
    check(audit.markConnected(sessionID: sessionID, at: connected),
          "connection audit records authentication success")
    check(
        audit.finish(sessionID: sessionID, status: .completed, at: ended, exitCode: 0),
        "connection audit completes an authenticated session"
    )
    check(
        !audit.finish(
            sessionID: sessionID,
            status: .failed,
            at: ended.addingTimeInterval(1),
            failureCode: "unknown",
            failureTitle: "should not replace"
        ) && audit.records.first?.status == .completed,
        "connection audit preserves the first trusted final result"
    )
    let reconnectRecordID = UUID()
    let reconnectStart = ended.addingTimeInterval(10)
    let reconnectID = audit.begin(
        sessionID: sessionID,
        host: host,
        username: "other-user",
        at: reconnectStart,
        sourceDeviceID: sourceDeviceID,
        sourceDeviceName: "Test Mac",
        recordID: reconnectRecordID
    )
    check(
        reconnectID == reconnectRecordID && audit.records.count == 2,
        "connection audit creates a distinct record when the same pane reconnects"
    )
    check(
        audit.markConnected(sessionID: sessionID, at: reconnectStart.addingTimeInterval(1)) &&
            audit.finish(
                sessionID: sessionID,
                status: .completed,
                at: reconnectStart.addingTimeInterval(5),
                exitCode: 0
            ) &&
            audit.records.filter({ $0.sessionID == sessionID && $0.status == .completed }).count == 2,
        "connection audit updates only the newest ongoing reconnect attempt"
    )

    var platformSnapshot = ConnectionAuditIndex()
    var platformUnknownHost = host
    platformUnknownHost.detectedPlatform = nil
    let platformSessionID = UUID()
    platformSnapshot.begin(
        sessionID: platformSessionID,
        host: platformUnknownHost,
        username: platformUnknownHost.username,
        at: start
    )
    check(
        platformSnapshot.recordDetectedPlatform(
            sessionID: platformSessionID,
            platform: .ubuntu
        ) && platformSnapshot.records.first?.platform == .ubuntu,
        "connection audit fills an initially unknown platform from the same session"
    )
    _ = platformSnapshot.finish(
        sessionID: platformSessionID,
        status: .completed,
        at: ended
    )
    check(
        !platformSnapshot.recordDetectedPlatform(
            sessionID: platformSessionID,
            platform: .debian
        ) && platformSnapshot.records.first?.platform == .ubuntu,
        "connection audit preserves the first detected platform snapshot"
    )
    let latePlatformSessionID = UUID()
    platformSnapshot.begin(
        sessionID: latePlatformSessionID,
        host: platformUnknownHost,
        username: platformUnknownHost.username,
        at: start
    )
    _ = platformSnapshot.finish(
        sessionID: latePlatformSessionID,
        status: .completed,
        at: ended
    )
    check(
        platformSnapshot.recordDetectedPlatform(
            sessionID: latePlatformSessionID,
            platform: .debian
        ) && platformSnapshot.records.first(where: { $0.sessionID == latePlatformSessionID })?.platform == .debian,
        "connection audit accepts a late platform callback for its finalized session"
    )
    check(
        !platformSnapshot.recordDetectedPlatform(
            sessionID: UUID(),
            platform: .centOS
        ) && platformSnapshot.records.filter({ $0.platform != nil }).count == 2,
        "connection audit never backfills unrelated historical sessions"
    )
    let reusedPlatformSessionID = UUID()
    platformSnapshot.begin(
        sessionID: reusedPlatformSessionID,
        host: platformUnknownHost,
        username: platformUnknownHost.username,
        at: start
    )
    _ = platformSnapshot.finish(
        sessionID: reusedPlatformSessionID,
        status: .completed,
        at: ended
    )
    platformSnapshot.begin(
        sessionID: reusedPlatformSessionID,
        host: platformUnknownHost,
        username: platformUnknownHost.username,
        at: ended.addingTimeInterval(1)
    )
    check(
        platformSnapshot.recordDetectedPlatform(
            sessionID: reusedPlatformSessionID,
            platform: .ubuntu
        ) &&
            platformSnapshot.records.filter({ $0.sessionID == reusedPlatformSessionID }).count == 2 &&
            platformSnapshot.records.filter({ $0.sessionID == reusedPlatformSessionID }).first?.platform == nil &&
            platformSnapshot.records.filter({ $0.sessionID == reusedPlatformSessionID }).last?.platform == .ubuntu,
        "connection audit applies platform detection only to the newest reconnect attempt"
    )

    var interrupted = ConnectionAuditIndex()
    interrupted.begin(sessionID: UUID(), host: host, username: host.username, at: start)
    check(interrupted.recoverInterruptedSessions(),
          "connection audit recovers an unfinished prior app session")
    check(
        interrupted.records.first?.status == .interrupted &&
            interrupted.records.first?.endedAt == nil,
        "interrupted audit does not invent an end time"
    )

    var pruned = ConnectionAuditIndex(maximumRecordCount: 2)
    let ongoingID = UUID()
    pruned.begin(sessionID: ongoingID, host: host, username: host.username, at: start)
    let oldID = UUID()
    pruned.begin(sessionID: oldID, host: host, username: host.username, at: start.addingTimeInterval(1))
    _ = pruned.finish(sessionID: oldID, status: .completed, at: ended)
    let newID = UUID()
    pruned.begin(sessionID: newID, host: host, username: host.username, at: start.addingTimeInterval(2))
    _ = pruned.finish(sessionID: newID, status: .failed, at: ended)
    check(
        pruned.records.count == 2 &&
            pruned.records.contains(where: { $0.sessionID == ongoingID }) &&
            !pruned.records.contains(where: { $0.sessionID == oldID }),
        "connection audit pruning preserves ongoing records and removes the oldest final record"
    )

    var retention = ConnectionAuditIndex(maximumRecordCount: 10)
    let expiredID = UUID()
    retention.begin(sessionID: expiredID, host: host, username: host.username, at: start)
    _ = retention.finish(sessionID: expiredID, status: .completed, at: ended)
    let retainedID = UUID()
    retention.begin(
        sessionID: retainedID,
        host: host,
        username: host.username,
        at: ended.addingTimeInterval(10)
    )
    _ = retention.finish(
        sessionID: retainedID,
        status: .failed,
        at: ended.addingTimeInterval(20)
    )
    let retentionOngoingID = UUID()
    retention.begin(sessionID: retentionOngoingID, host: host, username: host.username, at: start)
    check(
        retention.pruneExpired(before: ended.addingTimeInterval(1)) &&
            !retention.records.contains(where: { $0.sessionID == expiredID }) &&
            retention.records.contains(where: { $0.sessionID == retainedID }) &&
            retention.records.contains(where: { $0.sessionID == retentionOngoingID }),
        "connection audit 30-day pruning removes only finalized records before the cutoff"
    )

    var migrated = ConnectionAuditIndex(records: audit.records)
    check(
        !migrated.backfillSourceDevice(id: UUID(), name: "Other Mac"),
        "connection audit device migration never overwrites an existing source snapshot"
    )

    let testDirectory = FileManager.default.temporaryDirectory.appending(
        path: "MyTerm-connection-audit-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: testDirectory) }
    let testFile = testDirectory.appending(path: "connection-audit-log.json")
    let document = ConnectionAuditDocument(records: audit.records)
    try ConnectionAuditStore.saveDocument(document, to: testFile)
    let decoded = try ConnectionAuditStore.loadDocument(from: testFile)
    check(decoded == document, "connection audit document survives secure persistence round trip")
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: testDirectory.path)[.posixPermissions] as? NSNumber
    let filePermissions = try FileManager.default.attributesOfItem(atPath: testFile.path)[.posixPermissions] as? NSNumber
    check(directoryPermissions?.intValue == 0o700,
          "connection audit directory uses owner-only permissions")
    check(filePermissions?.intValue == 0o600,
          "connection audit file uses owner-only permissions")
    let persistedText = String(decoding: try Data(contentsOf: testFile), as: UTF8.self).lowercased()
    check(
        !persistedText.contains("password") &&
            !persistedText.contains("privatekey") &&
            !persistedText.contains("technical") &&
            !persistedText.contains("terminaloutput"),
        "connection audit persistence contains no credential or terminal transcript fields"
    )

    try Data("not-json".utf8).write(to: testFile)
    do {
        _ = try ConnectionAuditStore.loadDocument(from: testFile)
        check(false, "corrupt connection audit is rejected and backed up")
    } catch {
        let backups = try FileManager.default.contentsOfDirectory(
            at: testDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("connection-audit-log-corrupt-") }
        check(backups.count == 1 && !FileManager.default.fileExists(atPath: testFile.path),
              "corrupt connection audit is rejected and backed up")
    }
} catch {
    check(false, "connection audit model and persistence tests: \(error)")
}

do {
    var alpha = baseHost()
    alpha.name = "Alpha"
    var beta = baseHost()
    beta.name = "Beta"
    var gamma = baseHost()
    gamma.name = "Gamma"
    let canonicalHosts = [alpha, beta, gamma]

    var recency = HostConnectionRecencyIndex()
    recency.recordSuccessfulConnection(
        for: alpha.id,
        at: Date(timeIntervalSince1970: 100)
    )
    recency.recordSuccessfulConnection(
        for: gamma.id,
        at: Date(timeIntervalSince1970: 200)
    )
    check(
        recency.sortingByMostRecentConnection(
            canonicalHosts,
            canonicalHosts: canonicalHosts
        ).map(\.id) == [gamma.id, alpha.id, beta.id],
        "recently connected hosts sort newest first before never-connected hosts"
    )

    var tiedRecency = HostConnectionRecencyIndex()
    tiedRecency.recordSuccessfulConnection(
        for: alpha.id,
        at: Date(timeIntervalSince1970: 300)
    )
    tiedRecency.recordSuccessfulConnection(
        for: beta.id,
        at: Date(timeIntervalSince1970: 300)
    )
    check(
        tiedRecency.sortingByMostRecentConnection(
            [beta, alpha, gamma],
            canonicalHosts: canonicalHosts
        ).map(\.id) == [alpha.id, beta.id, gamma.id],
        "equal recency preserves canonical host ordering"
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(recency)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var decoded = try decoder.decode(HostConnectionRecencyIndex.self, from: encoded)
    check(decoded == recency, "host connection recency survives encoding and decoding")

    decoded.prune(validHostIDs: Set([alpha.id]))
    check(
        decoded.lastConnectedAt(for: alpha.id) != nil &&
            decoded.lastConnectedAt(for: gamma.id) == nil,
        "host connection recency prunes records for missing hosts"
    )
} catch {
    check(false, "host connection recency tests: \(error)")
}

do {
    let sourceGroupID = UUID()
    let targetGroupID = UUID()
    var movingHost = baseHost()
    movingHost.name = "Move Me"
    movingHost.groupID = sourceGroupID
    let untouchedHost = baseHost()
    let movedAt = Date(timeIntervalSince1970: 500)

    let movedHosts = try HostGroupMoveMutation.applying(
        hostID: movingHost.id,
        targetGroupID: targetGroupID,
        validGroupIDs: [sourceGroupID, targetGroupID],
        to: [movingHost, untouchedHost],
        at: movedAt
    )
    check(movedHosts?[0].groupID == targetGroupID, "host group move replaces the previous group")
    check(movedHosts?[0].updatedAt == movedAt, "host group move updates the modification time")
    check(movedHosts?[0].id == movingHost.id, "host group move preserves the host identity")
    check(movedHosts?[1] == untouchedHost, "host group move leaves other hosts unchanged")

    let sameGroupResult = try HostGroupMoveMutation.applying(
        hostID: movingHost.id,
        targetGroupID: sourceGroupID,
        validGroupIDs: [sourceGroupID, targetGroupID],
        to: [movingHost],
        at: movedAt
    )
    check(sameGroupResult == nil, "moving a host to its current group is a no-op")

    let ungroupedHosts = try HostGroupMoveMutation.applying(
        hostID: movingHost.id,
        targetGroupID: nil,
        validGroupIDs: [sourceGroupID, targetGroupID],
        to: [movingHost],
        at: movedAt
    )
    check(ungroupedHosts?[0].groupID == nil, "host group move can return a host to ungrouped")

    do {
        _ = try HostGroupMoveMutation.applying(
            hostID: movingHost.id,
            targetGroupID: UUID(),
            validGroupIDs: [sourceGroupID, targetGroupID],
            to: [movingHost]
        )
        check(false, "host group move rejects a missing target group")
    } catch {
        check(
            error as? HostGroupMoveError == .missingGroup,
            "host group move rejects a missing target group"
        )
    }

    do {
        _ = try HostGroupMoveMutation.applying(
            hostID: UUID(),
            targetGroupID: targetGroupID,
            validGroupIDs: [sourceGroupID, targetGroupID],
            to: [movingHost]
        )
        check(false, "host group move rejects a missing host")
    } catch {
        check(
            error as? HostGroupMoveError == .missingHost,
            "host group move rejects a missing host"
        )
    }

    let hostFrame = CGRect(x: 20, y: 140, width: 300, height: 76)
    check(
        HostGroupDropHitTesting.hostID(
            at: CGPoint(x: 170, y: 178),
            hostFrames: [movingHost.id: hostFrame]
        ) == movingHost.id,
        "host card center starts a measured drag"
    )
    let groupFrame = CGRect(x: 20, y: 30, width: 300, height: 76)
    check(
        HostGroupDropHitTesting.groupID(
            at: CGPoint(x: 170, y: 68),
            groupFrames: [targetGroupID: groupFrame],
            excluding: sourceGroupID
        ) == targetGroupID,
        "host group drop hit testing accepts the card center"
    )
    check(
        HostGroupDropHitTesting.groupID(
            at: CGPoint(x: 170, y: 101),
            groupFrames: [targetGroupID: groupFrame],
            excluding: sourceGroupID
        ) == targetGroupID,
        "host group drop hit testing accepts the card lower edge"
    )
    check(
        HostGroupDropHitTesting.groupID(
            at: CGPoint(x: 170, y: 120),
            groupFrames: [targetGroupID: groupFrame],
            excluding: sourceGroupID
        ) == nil,
        "host group drop hit testing rejects points outside the card"
    )
    check(
        HostGroupDropHitTesting.groupID(
            at: CGPoint(x: 170, y: 68),
            groupFrames: [sourceGroupID: groupFrame],
            excluding: sourceGroupID
        ) == nil,
        "host group drop hit testing excludes the current group"
    )
} catch {
    check(false, "host group move tests: \(error)")
}

check(
    !HostLibraryDragCleanupReason.monitorReplacement.notifiesSwiftUICancellation,
    "host drag monitor replacement does not notify SwiftUI cancellation state"
)
check(
    !HostLibraryDragCleanupReason.viewTeardown.notifiesSwiftUICancellation,
    "host drag monitor teardown does not notify SwiftUI cancellation state"
)
check(
    HostLibraryDragCleanupReason.userCancellation.notifiesSwiftUICancellation,
    "host drag monitor user cancellation notifies SwiftUI state"
)

do {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    var workspaces = TerminalWorkspaceCollection()

    let firstWorkspaceID = workspaces.add(sessionID: first)
    let secondWorkspaceID = workspaces.add(sessionID: second)
    let thirdWorkspaceID = workspaces.add(sessionID: third)
    check(workspaces.workspaces.map(\.sessionIDs) == [[first], [second], [third]],
          "new terminal sessions create ordered single-pane workspaces")
    check(workspaces.selectedWorkspaceID == thirdWorkspaceID && workspaces.selectedSessionID == third,
          "new terminal session selects its workspace")

    _ = workspaces.moveWorkspace(id: thirdWorkspaceID, toInsertionIndex: 0)
    check(workspaces.workspaces.map(\.id) == [thirdWorkspaceID, firstWorkspaceID, secondWorkspaceID],
          "terminal workspaces reorder by insertion position")
    check(workspaces.selectedWorkspaceID == thirdWorkspaceID,
          "terminal workspace reordering preserves selection")
    check(workspaces.preferredMergeTargetID(for: thirdWorkspaceID) == firstWorkspaceID,
          "first terminal workspace falls forward to the following merge target")
    check(workspaces.preferredMergeTargetID(for: firstWorkspaceID) == thirdWorkspaceID,
          "middle terminal workspace prefers its previous merge target")
    check(workspaces.preferredMergeTargetID(for: secondWorkspaceID) == firstWorkspaceID,
          "last terminal workspace prefers its previous merge target")

    let mergedID = try workspaces.merge(
        sourceWorkspaceID: secondWorkspaceID,
        targetWorkspaceID: firstWorkspaceID,
        position: .top
    )
    let merged = workspaces.workspace(id: mergedID)
    check(merged?.sessionIDs == [second, first] && merged?.splitAxis == .vertical,
          "top drop creates an ordered vertical two-pane workspace")
    check(merged?.activeSessionID == second,
          "dragged terminal becomes the active pane after merging")

    do {
        _ = try workspaces.merge(
            sourceWorkspaceID: thirdWorkspaceID,
            targetWorkspaceID: mergedID,
            position: .right
        )
        check(false, "third terminal is rejected by a two-pane workspace")
    } catch TerminalWorkspaceMutationError.targetAlreadyHasTwoPanes {
        check(true, "third terminal is rejected by a two-pane workspace")
    }

    check(workspaces.toggleSplitAxis(for: mergedID),
          "two-pane workspace can toggle its split axis")
    check(workspaces.workspace(id: mergedID)?.splitAxis == .horizontal,
          "vertical workspace toggles to horizontal")
    _ = workspaces.setSplitRatio(0.9, for: mergedID)
    check(workspaces.workspace(id: mergedID)?.splitRatio == 0.75,
          "split ratio is clamped to a usable range")

    check(workspaces.focusOtherPane(in: mergedID),
          "two-pane workspace can focus its other pane")
    check(workspaces.workspace(id: mergedID)?.activeSessionID == first,
          "focus moves to the other terminal pane")

    _ = workspaces.close(sessionID: first)
    let collapsed = workspaces.workspace(id: mergedID)
    check(collapsed?.sessionIDs == [second] && collapsed?.splitAxis == nil,
          "closing one pane collapses the workspace without removing the other session")

    _ = workspaces.selectWorkspace(at: 0)
    let selectedBeforeAdjacent = workspaces.selectedWorkspaceID
    _ = workspaces.selectAdjacentWorkspace(offset: 1)
    check(workspaces.selectedWorkspaceID != selectedBeforeAdjacent,
          "adjacent workspace selection follows visual order")

    _ = workspaces.close(sessionID: third)
    _ = workspaces.close(sessionID: second)
    check(workspaces.workspaces.isEmpty && workspaces.selectedWorkspaceID == nil,
          "closing the last terminal removes its workspace and clears selection")
} catch {
    check(false, "terminal workspace state suite: \(error)")
}

do {
    var singleWorkspace = TerminalWorkspaceCollection()
    let onlyWorkspaceID = singleWorkspace.add(sessionID: UUID())
    check(singleWorkspace.preferredMergeTargetID(for: onlyWorkspaceID) == nil,
          "a lone terminal workspace has no merge target")
    check(singleWorkspace.preferredMergeTargetID(for: UUID()) == nil,
          "an unknown terminal workspace has no merge target")
}

for (position, expectedAxis, sourceComesFirst) in [
    (TerminalWorkspaceDropPosition.left, TerminalWorkspaceSplitAxis.horizontal, true),
    (.right, .horizontal, false),
    (.top, .vertical, true),
    (.bottom, .vertical, false),
] {
    do {
        let targetSessionID = UUID()
        let sourceSessionID = UUID()
        var directionWorkspaces = TerminalWorkspaceCollection()
        let targetWorkspaceID = directionWorkspaces.add(sessionID: targetSessionID)
        let sourceWorkspaceID = directionWorkspaces.add(sessionID: sourceSessionID)
        let mergedID = try directionWorkspaces.merge(
            sourceWorkspaceID: sourceWorkspaceID,
            targetWorkspaceID: targetWorkspaceID,
            position: position
        )
        let expectedSessions = sourceComesFirst
            ? [sourceSessionID, targetSessionID]
            : [targetSessionID, sourceSessionID]
        let merged = directionWorkspaces.workspace(id: mergedID)
        check(merged?.sessionIDs == expectedSessions && merged?.splitAxis == expectedAxis,
              "\(position.rawValue) drop creates the expected two-pane order and axis")
    } catch {
        check(false, "\(position.rawValue) drop direction suite: \(error)")
    }
}

do {
    let firstPane = UUID()
    let detachedPane = UUID()
    var detachableWorkspaces = TerminalWorkspaceCollection()
    let firstWorkspaceID = detachableWorkspaces.add(sessionID: firstPane)
    let secondWorkspaceID = detachableWorkspaces.add(sessionID: detachedPane)
    _ = try detachableWorkspaces.merge(
        sourceWorkspaceID: secondWorkspaceID,
        targetWorkspaceID: firstWorkspaceID,
        position: .right
    )

    let detachedWorkspaceID = try detachableWorkspaces.detach(
        sessionID: detachedPane,
        toInsertionIndex: 0
    )
    check(detachableWorkspaces.workspaces.map(\.sessionIDs) == [[detachedPane], [firstPane]],
          "detaching a pane creates an independent workspace at the requested tab position")
    check(detachableWorkspaces.workspace(id: firstWorkspaceID)?.splitAxis == nil,
          "detaching a pane collapses the original workspace to one pane")
    check(detachableWorkspaces.selectedWorkspaceID == detachedWorkspaceID
            && detachableWorkspaces.selectedSessionID == detachedPane,
          "the detached pane becomes the selected workspace")

    do {
        _ = try detachableWorkspaces.detach(sessionID: firstPane, toInsertionIndex: 0)
        check(false, "a single-pane workspace cannot be detached again")
    } catch TerminalWorkspaceMutationError.sourceMustBeSplit {
        check(true, "a single-pane workspace cannot be detached again")
    }
} catch {
    check(false, "terminal pane detach suite: \(error)")
}

check(
    TerminalReconnectPolicy.canReconnect(
        kind: .ssh,
        state: .disconnected(255),
        processIsRunning: false
    ),
    "a stopped disconnected SSH session can reconnect in place"
)
check(
    TerminalReconnectPolicy.canReconnect(
        kind: .ssh,
        state: .failed("連線失敗"),
        processIsRunning: false
    ),
    "a stopped failed SSH session can retry in place"
)
check(
    !TerminalReconnectPolicy.canReconnect(
        kind: .ssh,
        state: .connected,
        processIsRunning: true
    ) &&
        !TerminalReconnectPolicy.canReconnect(
            kind: .local,
            state: .disconnected(nil),
            processIsRunning: false
        ),
    "connected SSH and non-SSH sessions never reinterpret Return as reconnect"
)
check(
    TerminalReconnectPolicy.isReturnInput([0x0D][...]) &&
        TerminalReconnectPolicy.isReturnInput([0x0A][...]) &&
        !TerminalReconnectPolicy.isReturnInput([0x20][...]) &&
        !TerminalReconnectPolicy.isReturnInput([0x0D, 0x0A][...]),
    "only a single Return or newline byte triggers reconnect"
)
let normalReconnectReset = TerminalReconnectPresentationPolicy.resetModes(isAlternateBuffer: false)
let alternateReconnectReset = TerminalReconnectPresentationPolicy.resetModes(isAlternateBuffer: true)
check(
    !String(decoding: normalReconnectReset, as: UTF8.self).contains("?1049l") &&
        String(decoding: alternateReconnectReset, as: UTF8.self).contains("?1049l"),
    "reconnect exits the alternate buffer without restoring a stale normal-buffer cursor"
)
check(
    TerminalReconnectPresentationPolicy.bottomRow(for: 24) == 23 &&
        TerminalReconnectPresentationPolicy.bottomRow(for: 0) == 0,
    "reconnect output starts at the terminal bottom row"
)

let initializationPacket = SFTPProtocolCodec.initializationPacket()
check(initializationPacket == Data([0, 0, 0, 5, 1, 0, 0, 0, 3]),
      "SFTP v3 initialization packet is framed correctly")

let regularPermissions = SFTPPermissionMode(0o100644)
check(regularPermissions.octalString == "644" && regularPermissions.paddedOctalString == "0644",
      "SFTP permission mode masks file type bits and formats octal values")
check(regularPermissions.symbolicString(kind: .regularFile) == "-rw-r--r--",
      "SFTP regular-file permissions use symbolic notation")
check(SFTPPermissionMode(0o755).symbolicString(kind: .directory) == "drwxr-xr-x",
      "SFTP directory permissions use a directory prefix")
check(SFTPPermissionMode(0o755).symbolicString(kind: .symbolicLink) == "lrwxr-xr-x",
      "SFTP symbolic-link permissions use a link prefix")
check(SFTPPermissionMode(0o4755).symbolicString(kind: .regularFile) == "-rwsr-xr-x",
      "SFTP permission notation preserves setuid")
check(SFTPPermissionMode(0o2644).symbolicString(kind: .regularFile) == "-rw-r-Sr--",
      "SFTP permission notation distinguishes setgid without execute")
check(SFTPPermissionMode(0o1777).symbolicString(kind: .directory) == "drwxrwxrwt",
      "SFTP permission notation preserves sticky directories")
check(SFTPPermissionMode(0o1766).symbolicString(kind: .directory) == "drwxrw-rwT",
      "SFTP permission notation distinguishes sticky without execute")
check(SFTPPermissionMode(octalString: "755")?.rawValue == 0o755 &&
      SFTPPermissionMode(octalString: "0755")?.rawValue == 0o755 &&
      SFTPPermissionMode(octalString: "888") == nil,
      "SFTP octal permission input accepts only three or four valid digits")

var editedPermissions = SFTPPermissionMode(0o644)
editedPermissions.set(.execute, for: .owner, enabled: true)
check(editedPermissions.rawValue == 0o744 &&
      editedPermissions.symbolicString(kind: .regularFile) == "-rwxr--r--",
      "SFTP permission access matrix updates the matching octal bit")
editedPermissions.set(.setUserID, enabled: true)
editedPermissions.set(.write, for: .others, enabled: true)
check(editedPermissions.rawValue == 0o4746 && editedPermissions.contains(.setUserID),
      "SFTP permission editing preserves special bits while changing access rights")

do {
    var payload = SFTPPacketWriter()
    payload.append(SFTPPacketType.name)
    payload.append(UInt32(42))
    payload.append(UInt32(1))
    payload.append(string: "example.txt")
    payload.append(string: "-rw-r--r-- example.txt")
    payload.append(UInt32(0x0000_000D)) // size, permissions, timestamps
    payload.append(UInt64(12_345))
    payload.append(UInt32(0o100644))
    payload.append(UInt32(1_700_000_000))
    payload.append(UInt32(1_700_000_100))
    let framed = payload.framed()
    let packet = framed.dropFirst(4)
    var (type, reader) = try SFTPProtocolCodec.responseReader(Data(packet), expectedRequestID: 42)
    check(type == SFTPPacketType.name, "SFTP response type is decoded")
    let entries = try SFTPProtocolCodec.parseNameEntries(&reader)
    check(entries.count == 1 && entries[0].name == "example.txt",
          "SFTP directory name is decoded")
    check(entries[0].attributes.size == 12_345 && entries[0].attributes.kind == .regularFile,
          "SFTP v3 attributes and POSIX file type are decoded")
} catch {
    check(false, "SFTP directory packet round trip: \(error)")
}

do {
    var reader = SFTPPacketReader(Data([0, 0, 0, 10, 1, 2]))
    _ = try reader.readData()
    check(false, "truncated SFTP strings are rejected")
} catch SFTPProtocolError.malformedPacket {
    check(true, "truncated SFTP strings are rejected")
} catch {
    check(false, "truncated SFTP strings are rejected: \(error)")
}

do {
    let original = SFTPLocalDragPayload(paths: ["/tmp/one.txt", "/tmp/folder"])
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SFTPLocalDragPayload.self, from: encoded)
    check(decoded == original, "SFTP local multi-item drag payload round trips")

    let remote = SFTPRemoteDragPayload(
        sessionID: UUID(),
        sourceDirectory: "/home/tester",
        names: ["one.txt", "folder"]
    )
    let remoteEncoded = try JSONEncoder().encode(remote)
    let remoteDecoded = try JSONDecoder().decode(SFTPRemoteDragPayload.self, from: remoteEncoded)
    check(remoteDecoded == remote,
          "SFTP remote drag payload preserves its session and source directory")
} catch {
    check(false, "SFTP drag payload round trip: \(error)")
}

do {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-SFTP-Symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
    let target = root.appending(path: "OneDrive", directoryHint: .isDirectory)
    let link = root.appending(path: "OneDrive Link")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: root) }

    let entry = try LocalFileEntry.inspect(link)
    check(entry.isSymbolicLink, "SFTP local browser recognizes symbolic links")
    check(entry.isNavigableDirectory,
          "SFTP local browser treats a symbolic link to a directory as navigable")
    check(entry.navigableDirectoryURL == target.standardizedFileURL,
          "SFTP local browser resolves a linked directory inside MyTerm")
} catch {
    check(false, "SFTP linked-directory navigation: \(error)")
}

do {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-SFTP-Integration-\(UUID().uuidString)", directoryHint: .isDirectory)
    let remoteRoot = root.appending(path: "remote", directoryHint: .isDirectory)
    let sourceRoot = root.appending(path: "source", directoryHint: .isDirectory)
    let downloadRoot = root.appending(path: "download", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let client = try SFTPClient.connectForTesting(
        executableURL: URL(fileURLWithPath: "/usr/libexec/sftp-server"),
        arguments: ["-d", remoteRoot.path]
    )
    defer { client.close() }
    let resolvedRoot = try client.realPath(".")
    let canonicalResolvedRoot = URL(fileURLWithPath: resolvedRoot)
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
    let canonicalExpectedRoot = remoteRoot
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
    check(canonicalResolvedRoot == canonicalExpectedRoot,
          "SFTP transport resolves the server start directory")

    let sourceFile = sourceRoot.appending(path: "sample.txt")
    try Data("hello from MyTerm".utf8).write(to: sourceFile)
    var uploadProgress: UInt64 = 0
    try client.uploadItem(at: sourceFile, to: resolvedRoot) { completed, _ in
        uploadProgress = completed
    }
    check(uploadProgress == 17, "SFTP upload reports byte progress")

    var entries = try client.listDirectory(resolvedRoot)
    guard let uploaded = entries.first(where: { $0.name == "sample.txt" }) else {
        throw SFTPProtocolError.malformedPacket
    }
    check(uploaded.attributes.kind == .regularFile, "SFTP upload creates a regular remote file")

    do {
        try client.uploadItem(at: sourceFile, to: resolvedRoot) { _, _ in }
        check(false, "SFTP upload never overwrites an existing target")
    } catch SFTPFileOperationError.destinationExists {
        check(true, "SFTP upload never overwrites an existing target")
    }

    let existingNames = try client.existingItemNames(
        ["sample.txt", "not-present.txt"],
        in: resolvedRoot
    )
    check(existingNames == ["sample.txt"],
          "SFTP overwrite preflight reports only existing targets")

    let replacementData = Data("replacement".utf8)
    try replacementData.write(to: sourceFile)
    try client.uploadItem(at: sourceFile, to: resolvedRoot, overwrite: true) { _, _ in }
    let replacedRemoteData = try Data(contentsOf: remoteRoot.appending(path: "sample.txt"))
    check(replacedRemoteData == replacementData,
          "confirmed SFTP upload replaces an existing remote file")

    let renamedPath = resolvedRoot + "/renamed.txt"
    try client.rename(from: resolvedRoot + "/sample.txt", to: renamedPath)
    try client.setPermissions(0o640, at: renamedPath)
    let remotePermissions = try FileManager.default.attributesOfItem(atPath: remoteRoot.appending(path: "renamed.txt").path)[.posixPermissions] as? NSNumber
    check(remotePermissions?.uint32Value == 0o640, "SFTP permission changes reach the remote filesystem")

    entries = try client.listDirectory(resolvedRoot)
    guard let renamed = entries.first(where: { $0.name == "renamed.txt" }) else {
        throw SFTPProtocolError.malformedPacket
    }
    var downloadProgress: UInt64 = 0
    try client.downloadItem(renamed, from: resolvedRoot, to: downloadRoot) { completed, _ in
        downloadProgress = completed
    }
    let downloadedData = try Data(contentsOf: downloadRoot.appending(path: "renamed.txt"))
    check(downloadedData == replacementData && downloadProgress == UInt64(replacementData.count),
          "SFTP download preserves file bytes and reports progress")

    let downloadedFile = downloadRoot.appending(path: "renamed.txt")
    try Data("stale local copy".utf8).write(to: downloadedFile)
    try client.downloadItem(
        renamed,
        from: resolvedRoot,
        to: downloadRoot,
        overwrite: true
    ) { _, _ in }
    let replacedLocalData = try Data(contentsOf: downloadedFile)
    check(replacedLocalData == replacementData,
          "confirmed SFTP download safely replaces an existing local file")

    let tree = sourceRoot.appending(path: "tree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
    try Data("nested".utf8).write(to: tree.appending(path: "nested.txt"))
    try client.uploadItem(at: tree, to: resolvedRoot) { _, _ in }
    entries = try client.listDirectory(resolvedRoot)
    guard let remoteTree = entries.first(where: { $0.name == "tree" }) else {
        throw SFTPProtocolError.malformedPacket
    }
    let secondDownload = root.appending(path: "download-tree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: secondDownload, withIntermediateDirectories: false)
    try client.downloadItem(remoteTree, from: resolvedRoot, to: secondDownload) { _, _ in }
    let nestedDownloadData = try Data(contentsOf: secondDownload.appending(path: "tree/nested.txt"))
    check(
        nestedDownloadData == Data("nested".utf8),
        "SFTP recursively transfers directories"
    )

    try client.removeRecursively(path: renamedPath, kind: .regularFile)
    try client.removeRecursively(path: resolvedRoot + "/tree", kind: .directory)
    let remainingRemoteEntries = try client.listDirectory(resolvedRoot)
    check(remainingRemoteEntries.isEmpty,
          "SFTP recursive deletion removes only the selected remote targets")
} catch {
    check(false, "SFTP local-server integration: \(error)")
}

do {
    var host = baseHost()
    host.name = "  Production  "
    let validated = try host.validated()
    check(validated.name == "Production", "host name is trimmed")
} catch {
    check(false, "valid profile is accepted: \(error)")
}

do {
    let rootID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let childID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let inventory = InventoryDocument(
        groups: [
            HostGroup(id: rootID, name: "Infrastructure"),
            HostGroup(id: childID, name: "Production", parentID: rootID)
        ],
        hosts: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(inventory)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(InventoryDocument.self, from: data)
    check(decoded.schemaVersion == 3, "hierarchical inventory uses schema version 3")
    check(decoded.groups.first(where: { $0.id == childID })?.parentID == rootID,
          "nested group parent survives persistence")
} catch {
    check(false, "hierarchical inventory round trip: \(error)")
}

do {
    let legacyGroupJSON = """
    {"id":"20000000-0000-0000-0000-000000000001","name":"Legacy","createdAt":"2026-08-06T00:00:00Z"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let group = try decoder.decode(HostGroup.self, from: Data(legacyGroupJSON.utf8))
    check(group.parentID == nil, "pre-hierarchy groups migrate to the root level")
} catch {
    check(false, "pre-hierarchy group decodes: \(error)")
}

do {
    let root = HostGroup(name: "Production")
    let child = HostGroup(name: "Database", parentID: root.id)
    var host = baseHost()
    host.groupID = child.id
    host.authenticationMethod = .privateKey
    host.privateKeyPath = "/Users/example/.ssh/do-not-export-this-key"
    host.notes = "migration note"
    let data = try HostTransferService.exportData(groups: [root, child], hosts: [host])
    let text = String(decoding: data, as: UTF8.self)
    check(text.contains("myterm-host-export-v1"), "MyTerm export has a versioned format marker")
    check(!text.contains("do-not-export-this-key"), "MyTerm export excludes private-key paths")
    check(!text.contains("privateKeyPath"), "MyTerm export schema has no private-key path field")

    let payload = try HostTransferService.decodeImport(data: data)
    let merge = try HostTransferService.merge(
        existing: InventoryDocument(),
        payload: payload,
        duplicatePolicy: .skipExisting
    )
    let imported = merge.document.hosts.first
    let importedChild = imported?.groupID.flatMap { id in merge.document.groups.first { $0.id == id } }
    let importedParent = importedChild?.parentID.flatMap { id in merge.document.groups.first { $0.id == id } }
    check(merge.importedHostCount == 1 && merge.addedGroupCount == 2,
          "MyTerm export round trip imports hosts and nested groups")
    check(importedChild?.name == "Database" && importedParent?.name == "Production",
          "MyTerm export round trip preserves group hierarchy")
    check(imported?.authenticationMethod == .sshAgent && imported?.privateKeyPath.isEmpty == true,
          "imported private-key references safely fall back to SSH Agent")
} catch {
    check(false, "MyTerm secure export and round trip: \(error)")
}

let syntheticTermiusExport = Data("""
{
  "format": "myterm-termius-host-export-v1",
  "source": "Synthetic Termius test fixture",
  "groups": [
    {"sourceID": 1, "name": "Infrastructure", "parentSourceID": null},
    {"sourceID": 2, "name": "Production", "parentSourceID": 1}
  ],
  "hosts": [
    {
      "name": "Example Web",
      "hostname": "192.0.2.10",
      "port": 22,
      "username": "operator",
      "group": "Infrastructure / Production",
      "detectedPlatform": "linux",
      "hasTermiusPrivateKey": false
    },
    {
      "name": "Example Web Duplicate",
      "hostname": "192.0.2.10",
      "port": 22,
      "username": "operator",
      "group": "Infrastructure / Production",
      "detectedPlatform": "linux",
      "hasTermiusPrivateKey": false
    },
    {
      "name": "Example Key Host",
      "hostname": "198.51.100.20",
      "port": 2222,
      "username": "admin",
      "group": "Infrastructure",
      "detectedPlatform": null,
      "hasTermiusPrivateKey": true
    }
  ]
}
""".utf8)

do {
    let payload = try HostTransferService.decodeImport(data: syntheticTermiusExport)
    let merge = try HostTransferService.merge(
        existing: InventoryDocument(),
        payload: payload,
        duplicatePolicy: .skipExisting
    )
    check(payload.format == .termius, "Termius metadata export format is recognized")
    check(payload.groups.count == 2 && payload.hosts.count == 3,
          "Termius export parses groups and hosts")
    check(merge.sourceDuplicateCount == 1 && merge.importedHostCount == 2,
          "Termius duplicate connection is detected and skipped by default")
    let nestedGroup = merge.document.groups.first { $0.name == "Production" }
    let parent = nestedGroup?.parentID.flatMap { id in merge.document.groups.first { $0.id == id } }
    check(parent?.name == "Infrastructure", "Termius nested groups are reconstructed")
} catch {
    check(false, "Termius export integration import: \(error)")
}

do {
    let payload = try HostTransferService.decodeImport(data: syntheticTermiusExport)
    let selectedIndex = payload.hosts.firstIndex { $0.name == "Example Web" }!
    let selected = payload.selectingHostIndices([selectedIndex])
    let merge = try HostTransferService.merge(
        existing: InventoryDocument(),
        payload: selected,
        duplicatePolicy: .skipExisting
    )
    check(selected.hosts.count == 1, "custom import selection keeps only checked hosts")
    check(Set(selected.groups.map(\.name)) == Set(["Infrastructure", "Production"]),
          "custom import selection keeps only the required group ancestry")
    check(merge.importedHostCount == 1 && merge.addedGroupCount == 2,
          "small-scope Termius import produces one host and its two required groups")

    let privateKeyIndex = payload.hosts.firstIndex { $0.name == "Example Key Host" }!
    let privateKeySelection = payload.selectingHostIndices([privateKeyIndex])
    check(privateKeySelection.referencedPrivateKeyCount == 1,
          "custom selection recalculates private-key warnings for checked hosts")

    var duplicate = HostProfile()
    duplicate.name = "Already here"
    duplicate.hostname = selected.hosts[0].hostname
    duplicate.port = selected.hosts[0].port
    duplicate.username = selected.hosts[0].username
    let skipped = try HostTransferService.merge(
        existing: InventoryDocument(hosts: [duplicate]),
        payload: selected,
        duplicatePolicy: .skipExisting
    )
    check(skipped.importedHostCount == 0 && skipped.addedGroupCount == 0,
          "groups needed only by a skipped custom-selection duplicate are not created")
} catch {
    check(false, "custom host selection import: \(error)")
}

do {
    let group = HostGroup(name: "Existing")
    var existingHost = baseHost()
    existingHost.groupID = group.id
    let export = try HostTransferService.exportData(groups: [group], hosts: [existingHost])
    let payload = try HostTransferService.decodeImport(data: export)
    let existing = InventoryDocument(groups: [group], hosts: [existingHost])
    let skip = try HostTransferService.merge(existing: existing, payload: payload, duplicatePolicy: .skipExisting)
    let keep = try HostTransferService.merge(existing: existing, payload: payload, duplicatePolicy: .keepBoth)
    check(skip.existingConflictCount == 1 && skip.skippedDuplicateCount == 1 && skip.importedHostCount == 0,
          "default import policy does not duplicate an existing connection")
    check(keep.importedHostCount == 1 && keep.document.hosts.count == 2,
          "keep-both import policy is available when duplicate profiles are intentional")
    check(skip.addedGroupCount == 0, "matching full group paths are reused")
} catch {
    check(false, "import duplicate policy: \(error)")
}

do {
    var host = baseHost()
    host.name = ""
    host.username = ""
    let validated = try host.validated()
    check(validated.displayName == "192.0.2.10", "blank name falls back to hostname")
    check(validated.username.isEmpty, "blank default username is accepted")
} catch {
    check(false, "optional name and username are accepted: \(error)")
}

do {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-SyncJournal-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "mutation-journal.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = SyncMutationJournal(fileURL: fileURL)
    let deviceID = UUID()
    let hostID = UUID()
    let groupID = UUID()

    let initialEntries = try journal.entries()
    check(initialEntries.isEmpty, "sync mutation journal starts empty")
    let first = try journal.enqueue(
        recordID: hostID,
        recordType: .host,
        operation: .upsert,
        deviceID: deviceID
    )
    let second = try journal.enqueue(
        recordID: groupID,
        recordType: .group,
        operation: .delete,
        deviceID: deviceID
    )
    check(first.sequence == 1 && second.sequence == 2,
          "sync mutation journal assigns stable increasing sequence numbers")

    let reloaded = SyncMutationJournal(fileURL: fileURL)
    let persisted = try reloaded.entries()
    check(persisted.map(\.recordID) == [hostID, groupID],
          "sync mutation journal survives process-style reload")
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
          "sync mutation journal uses owner-only permissions")
    let journalText = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    check(!journalText.contains("hostname") && !journalText.contains("password"),
          "sync mutation journal contains no host fields or passwords")

    try reloaded.acknowledge([first.id])
    let entriesAfterAcknowledgement = try reloaded.entries()
    check(entriesAfterAcknowledgement.map(\.id) == [second.id],
          "acknowledged sync mutations are removed without dropping pending entries")
    try reloaded.removeAll()
    let entriesAfterRemoval = try reloaded.entries()
    check(entriesAfterRemoval.isEmpty, "sync mutation journal can be cleared after upload")
} catch {
    check(false, "sync mutation journal lifecycle: \(error)")
}

do {
    let record = EncryptedSyncRecord(
        id: UUID(),
        recordType: .host,
        ciphertext: Data([0x10, 0x20, 0x30]),
        nonce: Data([0x40, 0x50]),
        authenticationTag: Data([0x60, 0x70]),
        keyVersion: 1,
        formatVersion: 1,
        revision: 2,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedByDeviceID: UUID(),
        deleted: false
    )
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(EncryptedSyncRecord.self, from: data)
    check(decoded == record, "encrypted sync record survives serialization")
} catch {
    check(false, "encrypted sync record serialization: \(error)")
}

do {
    let pkce = try OAuthPKCE.generate()
    check((43...128).contains(pkce.verifier.count), "OAuth PKCE verifier length follows RFC 7636")
    check(pkce.challenge.count == 43, "OAuth PKCE S256 challenge has the expected length")
    check(
        OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "OAuth PKCE matches the RFC 7636 test vector"
    )
} catch {
    check(false, "OAuth PKCE generation: \(error)")
}

do {
    let errorPayload = Data(#"{"error":"invalid_grant","error_description":"Bad verifier\nretry"}"#.utf8)
    let diagnostic = GoogleFirebaseAuthClient.googleErrorDiagnostic(from: errorPayload)
    check(diagnostic == "invalid_grant: Bad verifier retry",
          "Google token errors expose only a bounded safe diagnostic")
    check(GoogleFirebaseAuthClient.googleErrorDiagnostic(from: Data("not-json".utf8)) == "unknown_error",
          "invalid Google token errors do not expose raw response bodies")
}

do {
    let callback = try OAuthCallback.parse(
        requestTarget: "/oauth2/callback?code=test-code&state=test-state"
    )
    check(callback.code == "test-code", "OAuth callback extracts the authorization code")
    check(callback.state == "test-state", "OAuth callback extracts state")
    check(OAuthConstantTime.equal("same-state", "same-state"), "OAuth state comparison accepts equal values")
    check(!OAuthConstantTime.equal("same-state", "other-state"), "OAuth state comparison rejects unequal values")
} catch {
    check(false, "OAuth callback parsing: \(error)")
}

do {
    let claims: [String: Any] = [
        "iss": "https://accounts.google.com",
        "aud": "123456.apps.googleusercontent.com",
        "exp": Date().addingTimeInterval(300).timeIntervalSince1970,
        "nonce": "expected-nonce"
    ]
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let token = "e30.\(OAuthBase64URL.encode(payload)).test-signature"
    try GoogleIDTokenClaimsValidator.validate(
        idToken: token,
        expectedClientID: "123456.apps.googleusercontent.com",
        expectedNonce: "expected-nonce"
    )
    check(true, "Google ID token claims bind the OAuth client and nonce")
    do {
        try GoogleIDTokenClaimsValidator.validate(
            idToken: token,
            expectedClientID: "123456.apps.googleusercontent.com",
            expectedNonce: "wrong-nonce"
        )
        check(false, "Google ID token claims reject a mismatched nonce")
    } catch OAuthSecurityError.invalidNonce {
        check(true, "Google ID token claims reject a mismatched nonce")
    }
} catch {
    check(false, "Google ID token claims validation: \(error)")
}

do {
    let plist: [String: Any] = [
        "GOOGLE_DESKTOP_CLIENT_ID": "123456.apps.googleusercontent.com",
        "GOOGLE_DESKTOP_CLIENT_SECRET": "GOCSPX-unit-test-only",
        "FIREBASE_API_KEY": "AIzaValidUnitTestKey",
        "FIREBASE_PROJECT_ID": "myterm-test"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let configuration = try CloudConfiguration.parse(data)
    check(configuration.firebaseProjectID == "myterm-test", "cloud configuration accepts a valid project")
    check(
        configuration.googleDesktopClientID.hasSuffix(".apps.googleusercontent.com"),
        "cloud configuration requires a desktop Google client ID"
    )
    check(configuration.googleDesktopClientSecret == "GOCSPX-unit-test-only",
          "cloud configuration requires the paired desktop client secret")
    let client = GoogleFirebaseAuthClient(configuration: configuration)
    let authorizationURL = try client.authorizationURL(
        redirectURI: URL(string: "http://127.0.0.1:49152/oauth2/callback")!,
        pkce: OAuthPKCE(verifier: "verifier", challenge: "challenge"),
        state: "state-value",
        nonce: "nonce-value"
    )
    let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    check(authorizationURL.scheme == "https", "Google authorization always uses HTTPS")
    check(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256",
          "Google authorization requires PKCE S256")
    check(query.first(where: { $0.name == "state" })?.value == "state-value",
          "Google authorization includes state")
    check(query.first(where: { $0.name == "scope" })?.value == "openid email profile",
          "Google authorization requests only basic identity scopes")
} catch {
    check(false, "cloud configuration parsing: \(error)")
}

do {
    let legacyJSON = """
    [{
      "id":"00000000-0000-0000-0000-000000000001",
      "name":"Legacy",
      "hostname":"192.0.2.30",
      "port":22,
      "username":"operator",
      "group":"Production",
      "authenticationMethod":"password",
      "algorithmMode":"systemDefault",
      "createdAt":"2026-08-06T00:00:00Z",
      "updatedAt":"2026-08-06T00:00:00Z"
    }]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacyHosts = try decoder.decode([HostProfile].self, from: Data(legacyJSON.utf8))
    let inventory = InventoryDocument.migrating(legacyHosts)
    check(inventory.groups.map(\.name) == ["Production"], "legacy group becomes a first-class group")
    check(inventory.hosts.first?.groupID == inventory.groups.first?.id, "legacy host keeps its group assignment")
    check(inventory.hosts.first?.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"), "legacy host UUID is preserved")
} catch {
    check(false, "legacy inventory migrates: \(error)")
}

do {
    var host = baseHost()
    host.hostname = "-oProxyCommand=bad"
    _ = try host.validated()
    check(false, "option-like hostname is rejected")
} catch HostValidationError.invalidHostname {
    check(true, "option-like hostname is rejected")
} catch {
    check(false, "option-like hostname error type")
}

do {
    var host = baseHost()
    host.username = ""
    let arguments = try SSHArgumentBuilder.arguments(for: host, usernameOverride: "temporary")
    check(arguments.last == "temporary@192.0.2.10", "connection username can be supplied per session")
} catch {
    check(false, "temporary username builds SSH arguments: \(error)")
}

do {
    var host = baseHost()
    host.algorithmMode = .custom
    host.customAlgorithms.ciphers = "aes128-ctr bad"
    _ = try host.validated()
    check(false, "whitespace in algorithm is rejected")
} catch HostValidationError.invalidAlgorithm {
    check(true, "whitespace in algorithm is rejected")
} catch {
    check(false, "custom algorithm error type")
}

do {
    let arguments = try SSHArgumentBuilder.arguments(for: baseHost())
    let knownHostsOption = arguments.first { $0.hasPrefix("UserKnownHostsFile=") }
    check(!arguments.contains("HostKeyAlgorithms=+ssh-rsa"), "default does not enable ssh-rsa")
    check(arguments.last == "operator@192.0.2.10", "destination is last argument")
    check(arguments.contains("StrictHostKeyChecking=ask"), "strict host key checking is enabled")
    check(knownHostsOption?.contains("\"\(AppPaths.knownHostsFile.path)\"") == true
          && knownHostsOption?.contains("\"\(AppPaths.importedKnownHostsRawFile.path)\"") == true,
          "known-host paths containing spaces are quoted separately")
    check(arguments.contains("PreferredAuthentications=password,keyboard-interactive"),
          "static password authentication is preferred before keyboard-interactive")
} catch {
    check(false, "default SSH arguments build: \(error)")
}

do {
    let logURL = URL(fileURLWithPath: "/private/tmp/MyTerm-auth-test.log")
    let arguments = try SSHArgumentBuilder.arguments(for: baseHost(), connectionLogURL: logURL)
    check(arguments.contains("-v") && arguments.contains("-E") && arguments.contains(logURL.path),
          "password verification can use a private OpenSSH diagnostic log")
    check(arguments.last == "operator@192.0.2.10", "diagnostic options remain before the SSH destination")
} catch {
    check(false, "authentication diagnostic arguments build: \(error)")
}

do {
    var host = baseHost()
    host.algorithmMode = .rsaCompatibility
    let arguments = try SSHArgumentBuilder.arguments(for: host)
    check(arguments.contains("HostKeyAlgorithms=+ssh-rsa"), "RSA host-key compatibility is scoped")
    check(arguments.contains("PubkeyAcceptedAlgorithms=+ssh-rsa"), "RSA user-key compatibility is scoped")
} catch {
    check(false, "RSA arguments build: \(error)")
}

do {
    var host = baseHost()
    host.algorithmMode = .custom
    host.customAlgorithms.keyExchangeAlgorithms = "+diffie-hellman-group14-sha1"
    let arguments = try SSHArgumentBuilder.arguments(for: host)
    check(arguments.contains("KexAlgorithms=+diffie-hellman-group14-sha1"), "custom KEX is a separate argument")
} catch {
    check(false, "custom arguments build: \(error)")
}

let environment = SSHEnvironmentBuilder.environment(from: [
    "USER": "tester",
    "HOME": "/Users/tester",
    "SSH_AUTH_SOCK": "/tmp/agent.sock",
    "UNRELATED_SECRET": "must-not-pass"
])
check(environment.contains("SSH_AUTH_SOCK=/tmp/agent.sock"), "SSH agent socket is preserved")
check(!environment.contains { $0.contains("UNRELATED_SECRET") }, "unrelated environment secrets are filtered")

let localEnvironment = LocalTerminalEnvironmentBuilder.environment(from: [
    "USER": "tester",
    "HOME": "/Users/tester",
    "UNRELATED_SECRET": "must-not-pass"
])
check(localEnvironment.contains("SHELL=/bin/zsh"), "local terminal uses the fixed system zsh")
check(!localEnvironment.contains { $0.contains("UNRELATED_SECRET") }, "local terminal filters unrelated environment secrets")
check(
    LocalTerminalEnvironmentBuilder.currentDirectory()
        == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
    "local terminal starts in the current macOS user's home directory"
)

do {
    let suiteName = "MyTerm.ShortcutTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        check(false, "shortcut test defaults are available")
        throw CocoaError(.fileReadUnknown)
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = AppShortcutStore(defaults: defaults)
    check(store.shortcut(for: .pasteSavedPassword)?.displayText == "⌘P",
          "saved-password shortcut defaults to Command-P")
    check(store.shortcut(for: .openHosts) == nil,
          "shortcuts can be disabled by default")
    check(store.shortcut(for: .focusOtherPane) == nil,
          "focus-other-pane shortcut is available but disabled by default")

    let custom = AppShortcutDefinition(
        keyCode: 40,
        key: "K",
        modifiers: [.command, .option]
    )
    try store.assign(custom, to: .pasteSavedPassword)
    let reloaded = AppShortcutStore(defaults: defaults)
    check(reloaded.shortcut(for: .pasteSavedPassword) == custom,
          "custom shortcuts persist in local preferences")

    do {
        try store.assign(custom, to: .copyTerminal)
        check(false, "duplicate shortcuts are rejected")
    } catch AppShortcutAssignmentError.conflict(.pasteSavedPassword) {
        check(true, "duplicate shortcuts are rejected")
    } catch {
        check(false, "duplicate shortcut conflict identifies the existing action")
    }

    try store.assign(nil, to: .pasteSavedPassword)
    check(AppShortcutStore(defaults: defaults).shortcut(for: .pasteSavedPassword) == nil,
          "disabled shortcuts remain disabled after relaunch")

    do {
        try store.assign(.command(keyCode: 12, key: "Q"), to: .openHosts)
        check(false, "essential macOS shortcuts are reserved")
    } catch AppShortcutAssignmentError.reserved {
        check(true, "essential macOS shortcuts are reserved")
    } catch {
        check(false, "reserved shortcut reports the expected error")
    }
} catch {
    check(false, "shortcut settings round trip: \(error)")
}

let knownHostsFixture = """
# ignored comment
example.test ssh-ed25519 AQID imported
@revoked [192.0.2.40]:2222 ssh-rsa BAUG
|1|c2FsdA==|aGFzaA== ecdsa-sha2-nistp256 BwgJ
invalid line
example.test ssh-ed25519 AQID imported
"""
let parsedKnownHosts = KnownHostsParser.parse(knownHostsFixture)
check(parsedKnownHosts.count == 3, "known_hosts parser ignores comments, invalid lines and duplicates")
check(parsedKnownHosts.contains { $0.marker == "@revoked" }, "known_hosts markers are preserved")
check(parsedKnownHosts.contains { $0.isHashed }, "hashed known_hosts entries remain private")
check(parsedKnownHosts.first { $0.hostField == "example.test" }?.fingerprint.hasPrefix("SHA256:") == true,
      "known_hosts public-key fingerprint is calculated")

var platformDetector = HostPlatformDetector()
check(platformDetector.consume(Array("system-release -> alma".utf8)[...]) == nil,
      "platform detector waits for split evidence")
check(platformDetector.consume(Array("linux-release".utf8)[...]) == .almaLinux,
      "platform detector recognizes AlmaLinux output")
check(platformDetector.consume(Array("Ubuntu release".utf8)[...]) == nil,
      "platform detector records a platform only once")

var osReleaseDetector = HostPlatformDetector()
let fedoraOSRelease = """
NAME="Fedora Linux"
VERSION="42 (Workstation Edition)"
ID=fedora
"""
check(osReleaseDetector.consume(Array(fedoraOSRelease.utf8)[...]) == .fedora,
      "platform detector recognizes a background os-release probe")

var macOSPlatformDetector = HostPlatformDetector()
check(macOSPlatformDetector.consume(Array("Darwin workstation 25.0.0 arm64".utf8)[...]) == .macOS,
      "platform detector recognizes uname output from macOS")

do {
    var serial = SerialConfiguration()
    serial.devicePath = "/dev/cu.MyTerm-Test"
    serial.baudRate = 115_200
    serial.dataBits = 7
    serial.stopBits = 2
    serial.parity = .even
    serial.flowControl = .xonXoff
    let validated = try serial.validated(requireExistingDevice: false)
    check(validated.screenMode.contains("115200,cs7,ixon,ixoff"), "serial screen mode is explicit")
    check(validated.sttyArguments.contains("cstopb") && validated.sttyArguments.contains("-parodd"),
          "serial advanced stop-bit and parity settings are explicit")
} catch {
    check(false, "valid serial configuration is accepted: \(error)")
}

do {
    var serial = SerialConfiguration()
    serial.devicePath = "/dev/cu.safe\nmalicious"
    _ = try serial.validated(requireExistingDevice: false)
    check(false, "unsafe serial device path is rejected")
} catch SerialConfigurationError.invalidDevice {
    check(true, "unsafe serial device path is rejected")
} catch {
    check(false, "unsafe serial device path error type")
}

var promptDetector = LoginPasswordPromptDetector()
check(!promptDetector.consume(Array("operator@host's pass".utf8)[...]), "split password prompt waits")
check(promptDetector.consume(Array("word: ".utf8)[...]), "split password prompt is detected")
check(!promptDetector.consume(Array("[sudo] password: ".utf8)[...]), "login password auto-fill runs only once")

var savedPasswordPromptPolicy = LoginPasswordPromptPolicy()
check(savedPasswordPromptPolicy.nextAction(hasSavedPassword: true) == .useSavedPassword,
      "saved password is attempted automatically once")
check(savedPasswordPromptPolicy.nextAction(hasSavedPassword: true) == .captureAttempt,
      "a repeated login prompt captures a replacement attempt")
var unsavedPasswordPromptPolicy = LoginPasswordPromptPolicy()
check(unsavedPasswordPromptPolicy.nextAction(hasSavedPassword: false) == .captureAttempt,
      "an unsaved login prompt captures its first attempt")

var passwordPromptState = PasswordPromptStateDetector()
check(passwordPromptState.consume(Array("[sudo] pass".utf8)[...]) == nil,
      "manual password gate waits for a complete prompt")
check(passwordPromptState.consume(Array("word for operator: \u{1B}[?25h".utf8)[...]) == true,
      "manual password gate recognizes a sudo prompt with terminal escapes")
check(passwordPromptState.userDidSendInput() == false && !passwordPromptState.isAwaitingPassword,
      "any user input closes the manual password gate")
check(passwordPromptState.consume(Array("[operator@host ~]$ ".utf8)[...]) == nil,
      "ordinary shell prompts do not open the password gate")
check(passwordPromptState.consume(Array("operator 的密碼：".utf8)[...]) == true,
      "localized password prompts can open the password gate")
check(passwordPromptState.consume(Array("\nlogin complete".utf8)[...]) == false,
      "subsequent terminal output closes the password gate")
check(passwordPromptState.consume(Array("\nNew password:".utf8)[...]) == nil,
      "password-change and confirmation prompts do not open the saved-password gate")

var passwordCapture = LoginPasswordCapture()
check(passwordCapture.consume(Array("ignored".utf8)[...]) == .none,
      "password bytes are not captured before an SSH login prompt")
passwordCapture.begin()
check(passwordCapture.consume(Array("secrex".utf8)[...]) == .none,
      "password capture waits for submission")
_ = passwordCapture.consume([0x7F][...])
let correctedCapture = passwordCapture.consume(Array("t\r".utf8)[...])
check(correctedCapture == .submitted(Data("secret".utf8)),
      "password capture mirrors backspace and returns only the submitted attempt")
check(!passwordCapture.isCapturing, "password capture stops after one submitted attempt")

passwordCapture.begin()
_ = passwordCapture.consume(Array("wrong".utf8)[...])
_ = passwordCapture.consume([0x15][...])
let controlUResult = passwordCapture.consume(Array("correct\n".utf8)[...])
check(controlUResult == .submitted(Data("correct".utf8)),
      "Control-U removes an incorrect password before submission")

passwordCapture.begin()
check(passwordCapture.consume([0x03][...]) == .cancelled && !passwordCapture.isCapturing,
      "Control-C cancels password retention")

var isolatedNewPassword = PasswordChangeCapture()
check(isolatedNewPassword.consumeOutput(Array("New password:".utf8)[...]) == .none,
      "an isolated new-password prompt never captures a secret")
check(isolatedNewPassword.consumeInput(Array("must-not-capture\n".utf8)[...]) == .none,
      "unarmed password-change input is ignored")

var passwordChange = PasswordChangeCapture()
check(passwordChange.consumeOutput(Array("Current pass".utf8)[...]) == .none,
      "split current-password prompt waits")
check(passwordChange.consumeOutput(Array("word:".utf8)[...]) == .started,
      "current-password prompt arms a password-change sequence")
check(passwordChange.consumeInput(Array("old-password\n".utf8)[...]) == .none,
      "current password is never captured as the replacement")
check(passwordChange.consumeOutput(Array("\nNew password:".utf8)[...]) == .none,
      "new-password prompt starts private capture")
check(passwordChange.consumeInput(Array("new-secret\n".utf8)[...]) == .none,
      "new password waits for independent confirmation")
check(passwordChange.consumeOutput(Array("\nRetype new password:".utf8)[...]) == .none,
      "confirmation prompt starts a separate capture")
check(passwordChange.consumeInput(Array("new-secret\n".utf8)[...]) == .none,
      "matching confirmation waits for server success")
check(passwordChange.consumeOutput(Array("\npasswd: password updated ".utf8)[...]) == .none,
      "split password-change success waits")
check(passwordChange.consumeOutput(Array("successfully\n".utf8)[...]) == .verified(Data("new-secret".utf8)),
      "verified password change releases only the new password")

var mismatchedPasswordChange = PasswordChangeCapture()
_ = mismatchedPasswordChange.consumeOutput(Array("Current password:".utf8)[...])
_ = mismatchedPasswordChange.consumeOutput(Array("\nNew password:".utf8)[...])
_ = mismatchedPasswordChange.consumeInput(Array("first-secret\n".utf8)[...])
_ = mismatchedPasswordChange.consumeOutput(Array("\nRetype new password:".utf8)[...])
check(mismatchedPasswordChange.consumeInput(Array("different-secret\n".utf8)[...]) == .rejected,
      "mismatched new passwords are never retained")
check(mismatchedPasswordChange.consumeOutput(Array("password updated successfully".utf8)[...]) == .none,
      "a rejected password change cannot be revived by later text")

var failedPasswordChange = PasswordChangeCapture()
_ = failedPasswordChange.consumeOutput(Array("Current password:".utf8)[...])
_ = failedPasswordChange.consumeOutput(Array("\nNew password:".utf8)[...])
_ = failedPasswordChange.consumeInput(Array("new-secret\n".utf8)[...])
_ = failedPasswordChange.consumeOutput(Array("\nConfirm new password:".utf8)[...])
_ = failedPasswordChange.consumeInput(Array("new-secret\n".utf8)[...])
check(failedPasswordChange.consumeOutput(Array("\npasswd: password unchanged\n".utf8)[...]) == .rejected,
      "server rejection clears the candidate password")

var authLogDetector = SSHAuthenticationLogDetector()
check(authLogDetector.consume(Array("debug1: Authenticated to 192.0.".utf8)[...]) == nil,
      "split OpenSSH authentication evidence waits for completion")
check(authLogDetector.consume(Array("2.9 ([192.0.2.9]:22) using \"password\".\n".utf8)[...]) == .password,
      "OpenSSH password success evidence is recognized")

var keyboardInteractiveDetector = SSHAuthenticationLogDetector()
let keyboardInteractiveResult = keyboardInteractiveDetector.consume(
    Array("Authenticated to host ([192.0.2.1]:22) using \"keyboard-interactive\".\n".utf8)[...]
)
check(keyboardInteractiveResult == .other("keyboard-interactive"),
      "keyboard-interactive success is distinguished from a reusable password")

var connectionLogParser = SSHConnectionLogParser()
var connectionUpdate = connectionLogParser.consume(
    Array("debug1: Connecting to example.invalid [192.0.2.10] port 22.\ndebug1: Connection estab".utf8)[...]
)
check(connectionUpdate.events.map(\.phase) == [.connecting],
      "SSH connection diagnostics recognize the initial connection stage")
check(connectionUpdate.technicalLines.isEmpty,
      "SSH diagnostics use verbose connection lines internally without exposing them")
connectionUpdate = connectionLogParser.consume(
    Array("lished.\ndebug1: Authenticating to example.invalid:22 as 'operator'\nAuthenticated to example.invalid ([192.0.2.10]:22) using \"publickey\".\n".utf8)[...]
)
check(connectionUpdate.events.map(\.phase) == [.securing, .authenticating, .connected],
      "split SSH diagnostics advance through secure authentication stages")
check(connectionUpdate.authenticatedMethod == "publickey",
      "SSH diagnostics retain only the successful authentication method")
check(connectionUpdate.technicalLines == [
    "Authenticated to example.invalid ([192.0.2.10]:22) using \"publickey\"."
], "SSH diagnostics keep real non-debug OpenSSH authentication lines")
check(!connectionUpdate.events.contains { $0.message.contains("192.0.2.10") || $0.message.contains("operator") },
      "user-visible SSH diagnostic events omit raw infrastructure details")

var privatePathParser = SSHConnectionLogParser()
let privatePathUpdate = privatePathParser.consume(
    Array("debug1: Reading configuration data /Users/private/.ssh/config\ndebug1: identity file /Volumes/External/private/id_test type 3\nLoad key \"/Users/private/.ssh/id_test\": invalid format\n".utf8)[...]
)
check(privatePathUpdate.technicalLines == [
    "Load key \"<本機路徑>\": invalid format"
],
      "SSH diagnostics omit verbose configuration and identity lines while redacting error paths")
check(!privatePathUpdate.technicalLines.joined().contains("/Users/private")
        && !privatePathUpdate.technicalLines.joined().contains("/Volumes/External"),
      "SSH technical diagnostics never expose full local paths")

let rapidFailureTranscript = SSHConnectionLogParser.technicalTranscript(
    from: Data("debug1: Connecting to 127.0.0.1 [127.0.0.1] port 1.\ndebug1: connect to address 127.0.0.1 port 1: Connection refused\nssh: connect to host 127.0.0.1 port 1: Connection refused".utf8)
)
check(rapidFailureTranscript == [
    "ssh: connect to host 127.0.0.1 port 1: Connection refused"
], "rapid SSH failure finalization keeps the real error without verbose debug noise")

let verboseNoiseTranscript = SSHConnectionLogParser.technicalTranscript(
    from: Data("debug1: OpenSSH_10.2p1, LibreSSL 3.3.6\ndebug1: Reading configuration data /Users/private/.ssh/config\ndebug2: resolving \\\"example.invalid\\\" port 22\ndebug3: expanded UserKnownHostsFile '~/.ssh/known_hosts' -> '/Users/private/.ssh/known_hosts'\nssh: Could not resolve hostname example.invalid: nodename nor servname provided".utf8)
)
check(verboseNoiseTranscript == [
    "ssh: Could not resolve hostname example.invalid: nodename nor servname provided"
], "user-facing SSH transcript excludes every OpenSSH debug level")

let presentationBoundaryTranscript = SSHConnectionLogParser.userFacingTechnicalLines(from: [
    "debug1: Connecting to 127.0.0.1 port 1.",
    "debug2: resolving 127.0.0.1",
    "debug3: ssh_connect_direct: entering",
    "ssh: connect to host 127.0.0.1 port 1: Connection refused"
])
check(presentationBoundaryTranscript == [
    "ssh: connect to host 127.0.0.1 port 1: Connection refused"
], "SSH UI and clipboard presentation boundary rejects verbose lines from every source")

let carriageReturnTranscript = SSHConnectionLogParser.technicalTranscript(
    from: Data("debug1: OpenSSH_10.2p1, LibreSSL 3.3.6\rdebug1: Connecting to 127.0.0.1 port 1.\rdebug1: connect to address 127.0.0.1 port 1: Connection refused\rssh: connect to host 127.0.0.1 port 1: Connection refused\r".utf8)
)
check(carriageReturnTranscript == [
    "ssh: connect to host 127.0.0.1 port 1: Connection refused"
], "SSH transcript handles the carriage-return line endings emitted by the macOS OpenSSH log")

let combinedPresentationTranscript = SSHConnectionLogParser.userFacingTechnicalLines(from: [
    "debug1: OpenSSH_10.2p1\rdebug1: Connecting to 127.0.0.1 port 1.\rssh: connect to host 127.0.0.1 port 1: Connection refused"
])
check(combinedPresentationTranscript == [
    "ssh: connect to host 127.0.0.1 port 1: Connection refused"
], "SSH presentation boundary separates combined carriage-return records before filtering")

let failureSamples: [(String, SSHConnectionFailureKind)] = [
    ("ssh: Could not resolve hostname example.invalid: nodename nor servname provided", .addressResolution),
    ("connect to host 192.0.2.10 port 22: Operation timed out", .timeout),
    ("connect to host 192.0.2.10 port 2222: Connection refused", .refused),
    ("ssh: connect to host 192.0.2.10 port 22: No route to host", .unreachable),
    ("operator@example.invalid: Permission denied (publickey,password).", .authenticationRejected),
    ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", .hostKeyVerification),
    ("Unable to negotiate: no matching key exchange method found. Their offer: legacy", .keyExchangeAlgorithm),
    ("Unable to negotiate: no matching host key type found. Their offer: ssh-rsa", .hostKeyAlgorithm),
    ("Unable to negotiate: no matching cipher found. Their offer: 3des-cbc", .cipherAlgorithm),
    ("Load key \"/Users/private/.ssh/id_test\": invalid format", .privateKeyUnavailable),
    ("sign_and_send_pubkey: signing failed for RSA from agent: agent refused operation", .agentUnavailable),
    ("Connection closed by 192.0.2.10 port 22", .remoteClosed)
]
for (sample, expectedFailure) in failureSamples {
    var parser = SSHConnectionLogParser()
    let update = parser.consume(Array("\(sample)\n".utf8)[...])
    check(update.failure == expectedFailure,
          "SSH diagnostics classify \(expectedFailure.rawValue)")
    check(update.events.last?.technicalLine != nil,
          "SSH failure event carries the same redacted OpenSSH source line")
    check(!update.events.contains { $0.message.contains("/Users/private") || $0.message.contains("192.0.2.10") },
          "SSH failure diagnostics do not expose raw paths or addresses")
    check(!update.technicalLines.isEmpty,
          "SSH failure diagnostics retain a useful OpenSSH technical line")
    check(!update.technicalLines.joined().contains("/Users/private"),
          "SSH failure technical lines redact local paths")
}

do {
    let authenticationLog = try AppPaths.createSSHConnectionLog()
    let attributes = try FileManager.default.attributesOfItem(atPath: authenticationLog.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    check(permissions == 0o600, "OpenSSH authentication diagnostics use owner-only permissions")
    AppPaths.removeSSHConnectionLog(authenticationLog)
    check(!FileManager.default.fileExists(atPath: authenticationLog.path),
          "OpenSSH authentication diagnostics are removed after use")
} catch {
    check(false, "authentication diagnostic file lifecycle: \(error)")
}

do {
    let cleanupRoot = FileManager.default.temporaryDirectory
        .appending(path: "MyTerm-Stale-SSH-Logs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cleanupRoot) }

    let firstStaleLog = cleanupRoot.appending(path: "ssh-connection-\(UUID().uuidString).log")
    let secondStaleLog = cleanupRoot.appending(path: "ssh-connection-interrupted.log")
    let unrelatedLog = cleanupRoot.appending(path: "user-kept.log")
    let similarlyNamedFile = cleanupRoot.appending(path: "ssh-connection-not-a-log.txt")
    try Data("stale-one".utf8).write(to: firstStaleLog)
    try Data("stale-two".utf8).write(to: secondStaleLog)
    try Data("keep-log".utf8).write(to: unrelatedLog)
    try Data("keep-text".utf8).write(to: similarlyNamedFile)

    let removedCount = try AppPaths.removeStaleSSHConnectionLogs(in: cleanupRoot)
    check(removedCount == 2, "startup cleanup removes every stale MyTerm SSH diagnostic log")
    check(!FileManager.default.fileExists(atPath: firstStaleLog.path)
            && !FileManager.default.fileExists(atPath: secondStaleLog.path),
          "startup cleanup leaves no matching crash-remnant diagnostic logs")
    check(FileManager.default.fileExists(atPath: unrelatedLog.path)
            && FileManager.default.fileExists(atPath: similarlyNamedFile.path),
          "startup cleanup preserves unrelated files in the diagnostic directory")
} catch {
    check(false, "stale SSH diagnostic startup cleanup: \(error)")
}

let keychainTestID = UUID()
do {
    let result = try KeychainStore.deletionResult(for: errSecInvalidOwnerEdit)
    check(result == .manualCleanupRequired(errSecInvalidOwnerEdit),
          "Keychain owner mismatch becomes a non-blocking cleanup result")
    let missingResult = try KeychainStore.deletionResult(for: errSecItemNotFound)
    check(missingResult == .notFound,
          "missing Keychain password is safe to delete")
} catch {
    check(false, "Keychain deletion status classification: \(error)")
}

do {
    try KeychainStore.save(password: "MySSHClient-temporary-test", for: keychainTestID)
    let stored = try KeychainStore.passwordData(for: keychainTestID)
    check(stored == Data("MySSHClient-temporary-test".utf8), "Keychain secret round trip")
    try KeychainStore.deletePassword(for: keychainTestID)
    let deleted = try KeychainStore.passwordData(for: keychainTestID)
    check(deleted == nil, "Keychain test secret is deleted")
} catch {
    _ = try? KeychainStore.deletePassword(for: keychainTestID)
    check(false, "Keychain operations: \(error)")
}

let cloudKeychainTestProject = "myterm-unit-test-\(UUID().uuidString)"
do {
    let isolatedDefaultsSuite = "tw.local.MySSHClient.tests.cloud-session.\(UUID().uuidString)"
    guard let isolatedDefaults = UserDefaults(suiteName: isolatedDefaultsSuite) else {
        throw KeychainStoreError.invalidData
    }
    defer { isolatedDefaults.removePersistentDomain(forName: isolatedDefaultsSuite) }
    check(
        CloudSessionLegacyImportPolicy.resolve(
            developmentMode: false,
            updateLabMode: false
        ) == .productionCompatible,
        "production channel retains one-time legacy Firebase session migration"
    )
    check(
        CloudSessionLegacyImportPolicy.resolve(
            developmentMode: true,
            updateLabMode: false
        ) == .isolatedChannel,
        "development channel refuses the production legacy Firebase session"
    )
    check(
        CloudSessionLegacyImportPolicy.resolve(
            developmentMode: false,
            updateLabMode: true
        ) == .isolatedChannel,
        "update lab refuses the production legacy Firebase session"
    )
    try CloudSessionKeychainStore.saveRefreshToken(
        "firebase-refresh-token-test",
        projectID: cloudKeychainTestProject
    )
    let stored = try CloudSessionKeychainStore.refreshToken(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .isolatedChannel
    )
    check(
        stored == "firebase-refresh-token-test",
        "an isolated channel still restores a session already saved in its own vault"
    )
    let didResetIsolatedSession = try CloudSessionKeychainStore.resetIsolatedChannelSessionIfNeeded(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .isolatedChannel,
        defaults: isolatedDefaults
    )
    check(
        didResetIsolatedSession,
        "an isolated channel removes the previously imported session exactly once"
    )
    let resetToken = try CloudSessionKeychainStore.refreshToken(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .isolatedChannel
    )
    check(resetToken == nil, "the one-time isolated-channel reset leaves development signed out")
    try CloudSessionKeychainStore.saveRefreshToken(
        "development-owned-refresh-token",
        projectID: cloudKeychainTestProject
    )
    let didRepeatIsolatedReset = try CloudSessionKeychainStore.resetIsolatedChannelSessionIfNeeded(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .isolatedChannel,
        defaults: isolatedDefaults
    )
    check(
        !didRepeatIsolatedReset,
        "the isolated-channel reset does not repeat after its migration marker is saved"
    )
    let developmentOwnedToken = try CloudSessionKeychainStore.refreshToken(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .isolatedChannel
    )
    check(
        developmentOwnedToken == "development-owned-refresh-token",
        "a later development login survives rebuilds after the one-time reset"
    )
    let productionDefaultsSuite = "tw.local.MySSHClient.tests.production-session.\(UUID().uuidString)"
    guard let productionDefaults = UserDefaults(suiteName: productionDefaultsSuite) else {
        throw KeychainStoreError.invalidData
    }
    defer { productionDefaults.removePersistentDomain(forName: productionDefaultsSuite) }
    let didResetProductionSession = try CloudSessionKeychainStore.resetIsolatedChannelSessionIfNeeded(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .productionCompatible,
        defaults: productionDefaults
    )
    check(
        !didResetProductionSession,
        "production never runs the development session reset"
    )
    let productionCompatibleToken = try CloudSessionKeychainStore.refreshToken(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .productionCompatible
    )
    check(
        productionCompatibleToken == "development-owned-refresh-token",
        "the development isolation migration does not delete a production-compatible session"
    )
    _ = try CloudSessionKeychainStore.deleteRefreshToken(projectID: cloudKeychainTestProject)
    let deleted = try CloudSessionKeychainStore.refreshToken(
        projectID: cloudKeychainTestProject,
        legacyImportPolicy: .isolatedChannel
    )
    check(deleted == nil, "an isolated-channel Firebase refresh token is deleted without legacy fallback")
} catch {
    _ = try? CloudSessionKeychainStore.deleteRefreshToken(projectID: cloudKeychainTestProject)
    check(false, "Firebase refresh token Keychain operations: \(error)")
}

do {
    let firstHostID = UUID()
    let secondHostID = UUID()
    let firstSecret = Data("vault-host-secret-one".utf8)
    let secondSecret = Data("vault-host-secret-two".utf8)
    try KeychainStore.save(passwordData: firstSecret, for: firstHostID)
    try KeychainStore.save(passwordData: secondSecret, for: secondHostID)

    let loadedFirstSecret = try KeychainStore.passwordData(for: firstHostID)
    let loadedSecondSecret = try KeychainStore.passwordData(for: secondHostID)
    let usesDeviceOnlyAccessibility = try LocalSecretVaultStore
        .rootKeyUsesThisDeviceOnlyAccessibility()
    check(loadedFirstSecret == firstSecret,
          "unified local vault returns the first host password")
    check(loadedSecondSecret == secondSecret,
          "unified local vault returns the second host password")
    check(usesDeviceOnlyAccessibility,
          "unified local vault root key is restricted to this unlocked Mac")

    let encryptedBytes = try Data(contentsOf: LocalSecretVaultStore.fileURLForTesting)
    check(encryptedBytes.range(of: firstSecret) == nil && encryptedBytes.range(of: secondSecret) == nil,
          "unified local vault file contains no plaintext host password")
    let attributes = try FileManager.default.attributesOfItem(
        atPath: LocalSecretVaultStore.fileURLForTesting.path
    )
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    check(permissions == 0o600, "unified local vault file uses owner-only permissions")

    if let rootService = ProcessInfo.processInfo.environment["MYTERM_SECRET_VAULT_KEYCHAIN_SERVICE"] {
        let rootQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: rootService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        var rootItems: CFTypeRef?
        let status = SecItemCopyMatching(rootQuery as CFDictionary, &rootItems)
        let itemCount: Int
        if let items = rootItems as? [Any] {
            itemCount = items.count
        } else if status == errSecSuccess {
            itemCount = 1
        } else {
            itemCount = 0
        }
        check(status == errSecSuccess && itemCount == 1,
              "multiple secrets share exactly one Keychain root item")
    } else {
        check(false, "unified local vault test root service is configured")
    }

    _ = try KeychainStore.deletePassword(for: firstHostID)
    _ = try KeychainStore.deletePassword(for: secondHostID)
} catch {
    check(false, "unified local secret vault security suite: \(error)")
}

let legacyHostID = UUID()
let legacySecret = Data("legacy-password-migration-test".utf8)
let legacyQuery: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: KeychainStore.service,
    kSecAttrAccount: legacyHostID.uuidString
]
do {
    var insertion = legacyQuery
    insertion[kSecValueData] = legacySecret
    insertion[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let addStatus = SecItemAdd(insertion as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw KeychainStoreError.operationFailed(addStatus)
    }

    let backgroundVisibleSecret = try KeychainStore.unifiedPasswordData(for: legacyHostID)
    check(backgroundVisibleSecret == nil,
          "background sync does not unlock a legacy per-host Keychain password")
    let migratedLegacySecret = try KeychainStore.passwordData(for: legacyHostID)
    check(migratedLegacySecret == legacySecret,
          "legacy per-host Keychain password migrates into the unified vault")
    _ = try KeychainStore.deletePassword(for: legacyHostID)
    let deletedLegacySecret = try KeychainStore.passwordData(for: legacyHostID)
    check(deletedLegacySecret == nil,
          "deleted migrated password is not resurrected from legacy Keychain data")
    check(SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecSuccess,
          "legacy password can remain untouched to avoid another ACL prompt")
} catch {
    check(false, "legacy Keychain migration and suppression: \(error)")
}
SecItemDelete(legacyQuery as CFDictionary)

do {
    let corruptionService = "tw.local.MySSHClient.tests.corruption"
    try LocalSecretVaultStore.save(
        Data("authenticated-secret".utf8),
        service: corruptionService,
        account: "one"
    )
    let originalEnvelope = try Data(contentsOf: LocalSecretVaultStore.fileURLForTesting)
    try LocalSecretVaultStore.corruptAuthenticationTagForTesting()
    do {
        _ = try LocalSecretVaultStore.data(service: corruptionService, account: "one")
        check(false, "tampered local vault authentication tag is rejected")
    } catch LocalSecretVaultError.authenticationFailed {
        check(true, "tampered local vault authentication tag is rejected")
    } catch {
        check(false, "tampered local vault authentication tag is rejected: \(error)")
    }
    try originalEnvelope.write(to: LocalSecretVaultStore.fileURLForTesting, options: .atomic)
    let restoredSecret = try LocalSecretVaultStore.data(
        service: corruptionService,
        account: "one"
    )
    check(restoredSecret == Data("authenticated-secret".utf8),
          "authenticated vault remains readable after restoring its verified envelope")

    LocalSecretVaultStore.deleteRootKeyForTesting()
    do {
        try LocalSecretVaultStore.warmUp()
        check(false, "missing root key never overwrites an existing encrypted vault")
    } catch LocalSecretVaultError.missingRootKey {
        check(true, "missing root key never overwrites an existing encrypted vault")
    } catch {
        check(false, "missing root key never overwrites an existing encrypted vault: \(error)")
    }
} catch {
    check(false, "unified local vault tamper and root-loss protection: \(error)")
}

LocalSecretVaultStore.resetForTesting()
print("\n\(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
