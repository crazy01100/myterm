import Foundation

struct CommandSnippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var command: String
    var category = ""
    var note = ""

    func validated() throws -> Self {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty, result.title.count <= 80,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 16_384, result.category.count <= 40, note.count <= 1_000 else {
            throw CommandSnippetError.invalidContent
        }
        return result
    }

    var canInsert: Bool {
        !command.isEmpty && command.utf8.count <= 16_384 && !command.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }
    }
}

struct CommandSnippetDocument: Codable {
    var schemaVersion = 1
    var snippets: [CommandSnippet] = []
}

enum CommandSnippetError: LocalizedError {
    case invalidContent, limit, storageLimit, unreadable, unsupportedVersion, unsafeInput, unavailableTarget
    var errorDescription: String? {
        switch self {
        case .invalidContent: "請填寫名稱與指令；名稱限80字、分類40字、說明1,000字，指令限16KB。"
        case .limit: "指令庫最多保存500筆指令。"
        case .storageLimit: "指令庫已達16MB保存上限，請縮短指令內容或移除不需要的項目。"
        case .unreadable: "無法讀取指令庫，原始檔案已保留；暫停編輯以避免覆寫資料。"
        case .unsupportedVersion: "此指令庫由較新版本建立，請更新MyTerm；原始檔案已保留。"
        case .unsafeInput: "多行或含控制字元的指令僅供預覽與複製，不能直接填入終端。"
        case .unavailableTarget: "目標終端已變更或目前不適合接收指令，請重新選擇窗格並確認連線。"
        }
    }
}

// Conservative input guard, separate from the narrower saved-password eligibility detector.
struct SnippetInputPromptGuard {
    private var line = ""
    private(set) var isBlocked = false

    mutating func receive(_ bytes: ArraySlice<UInt8>) {
        for character in String(decoding: bytes, as: UTF8.self) {
            if character == "\r" || character == "\n" { line = ""; isBlocked = false }
            else { line.append(character) }
        }
        line = String(line.suffix(1_024))
        let lower = line.lowercased()
        if ["password", "passphrase", "verification code", "one-time", "otp", "密碼", "密码", "驗證碼", "验证码"]
            .contains(where: lower.contains) { isBlocked = true }
    }

    mutating func userInput(_ bytes: ArraySlice<UInt8>) {
        if bytes.contains(13) || bytes.contains(10) || bytes.contains(3) { line = ""; isBlocked = false }
    }
}

struct SnippetTargetIdentity: Equatable {
    let sessionID: UUID
    let attemptID: UUID

    func permits(currentSessionID: UUID?, currentAttemptID: UUID?, connected: Bool,
                 supported: Bool, passwordPrompt: Bool, alternateScreen: Bool) -> Bool {
        currentSessionID == sessionID && currentAttemptID == attemptID && connected && supported
            && !passwordPrompt && !alternateScreen
    }
}

// Only explicit navigation selects a destination. Layout changes and closing a
// pane must not silently redirect pending input to a surviving session.
struct SnippetTargetSelection: Equatable {
    private(set) var target: SnippetTargetIdentity?

    mutating func select(_ identity: SnippetTargetIdentity?) { target = identity }

    mutating func invalidate(sessionID: UUID) {
        if target?.sessionID == sessionID { target = nil }
    }

    func visibleTarget(currentSessionID: UUID?) -> SnippetTargetIdentity? {
        guard let target, target.sessionID == currentSessionID else { return nil }
        return target
    }
}
