import AppKit
import Combine
import Foundation

enum AppShortcutAction: String, CaseIterable, Codable, Identifiable {
    case copyTerminal
    case pasteTerminal
    case pasteSavedPassword
    case selectAllTerminal
    case increaseTerminalFont
    case decreaseTerminalFont
    case resetTerminalFont
    case openHosts
    case openLocalTerminal
    case openSerial
    case closeTab
    case nextTab
    case previousTab
    case focusOtherPane
    case tab1
    case tab2
    case tab3
    case tab4
    case tab5
    case tab6
    case tab7
    case tab8
    case tab9
    case findTerminal
    case disconnectSession

    var id: Self { self }

    var title: String {
        switch self {
        case .copyTerminal: "從終端機複製"
        case .pasteTerminal: "貼上至終端機"
        case .pasteSavedPassword: "填入已儲存的密碼"
        case .selectAllTerminal: "全選終端機內容"
        case .increaseTerminalFont: "放大終端字體"
        case .decreaseTerminalFont: "縮小終端字體"
        case .resetTerminalFont: "還原終端字體"
        case .openHosts: "開啟主機首頁"
        case .openLocalTerminal: "開啟本地 Terminal"
        case .openSerial: "開啟 Serial 連線"
        case .closeTab: "關閉目前窗格／分頁"
        case .nextTab: "下一個分頁"
        case .previousTab: "上一個分頁"
        case .focusOtherPane: "切換至另一個窗格"
        case .tab1: "切換至分頁 1"
        case .tab2: "切換至分頁 2"
        case .tab3: "切換至分頁 3"
        case .tab4: "切換至分頁 4"
        case .tab5: "切換至分頁 5"
        case .tab6: "切換至分頁 6"
        case .tab7: "切換至分頁 7"
        case .tab8: "切換至分頁 8"
        case .tab9: "切換至分頁 9"
        case .findTerminal: "搜尋終端機內容"
        case .disconnectSession: "中斷目前連線"
        }
    }

    var category: AppShortcutCategory {
        switch self {
        case .copyTerminal, .pasteTerminal, .pasteSavedPassword, .selectAllTerminal, .findTerminal,
             .increaseTerminalFont, .decreaseTerminalFont, .resetTerminalFont:
            .terminal
        case .openHosts, .openLocalTerminal, .openSerial, .disconnectSession:
            .session
        case .closeTab, .nextTab, .previousTab, .focusOtherPane,
             .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            .tabs
        }
    }

    var tabIndex: Int? {
        switch self {
        case .tab1: 0
        case .tab2: 1
        case .tab3: 2
        case .tab4: 3
        case .tab5: 4
        case .tab6: 5
        case .tab7: 6
        case .tab8: 7
        case .tab9: 8
        default: nil
        }
    }

    var defaultShortcut: AppShortcutDefinition? {
        switch self {
        case .copyTerminal: .command(keyCode: 8, key: "C")
        case .pasteTerminal: .command(keyCode: 9, key: "V")
        case .pasteSavedPassword: .command(keyCode: 35, key: "P")
        case .selectAllTerminal: .command(keyCode: 0, key: "A")
        case .increaseTerminalFont: .command(keyCode: 24, key: "+")
        case .decreaseTerminalFont: .command(keyCode: 27, key: "−")
        case .resetTerminalFont: .command(keyCode: 29, key: "0")
        case .openHosts: nil
        case .openLocalTerminal: .command(keyCode: 37, key: "L")
        case .openSerial: .commandOption(keyCode: 1, key: "S")
        case .closeTab: .command(keyCode: 13, key: "W")
        case .nextTab: .commandShift(keyCode: 30, key: "]")
        case .previousTab: .commandShift(keyCode: 33, key: "[")
        case .focusOtherPane: nil
        case .tab1: .command(keyCode: 18, key: "1")
        case .tab2: .command(keyCode: 19, key: "2")
        case .tab3: .command(keyCode: 20, key: "3")
        case .tab4: .command(keyCode: 21, key: "4")
        case .tab5: .command(keyCode: 23, key: "5")
        case .tab6: .command(keyCode: 22, key: "6")
        case .tab7: .command(keyCode: 26, key: "7")
        case .tab8: .command(keyCode: 28, key: "8")
        case .tab9: .command(keyCode: 25, key: "9")
        case .findTerminal: .command(keyCode: 3, key: "F")
        case .disconnectSession: nil
        }
    }

    var fontZoomAction: TerminalFontZoomAction? {
        switch self {
        case .increaseTerminalFont: .increase
        case .decreaseTerminalFont: .decrease
        case .resetTerminalFont: .reset
        default: nil
        }
    }

    // Only the default assignment owns aliases. Disabling or customizing the
    // action releases those combinations for other actions as well.
    func effectiveShortcuts(for assignment: AppShortcutDefinition) -> [AppShortcutDefinition] {
        guard let defaultShortcut, assignment.hasSameCombination(as: defaultShortcut) else {
            return [assignment]
        }
        switch self {
        case .increaseTerminalFont:
            return [assignment, .commandShift(keyCode: 24, key: "+"), .command(keyCode: 69, key: "+")]
        case .decreaseTerminalFont:
            return [assignment, .command(keyCode: 78, key: "−")]
        case .resetTerminalFont:
            return [assignment, .command(keyCode: 82, key: "0")]
        default:
            return [assignment]
        }
    }
}

enum AppShortcutCategory: String, CaseIterable, Identifiable {
    case terminal
    case session
    case tabs

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "終端機"
        case .session: "工作階段"
        case .tabs: "分頁"
        }
    }
}

struct AppShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    static func from(_ flags: NSEvent.ModifierFlags) -> Self {
        var result: Self = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    var displayText: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

struct AppShortcutDefinition: Codable, Hashable {
    let keyCode: UInt16
    let key: String
    let modifiers: AppShortcutModifiers

    static func command(keyCode: UInt16, key: String) -> Self {
        Self(keyCode: keyCode, key: key, modifiers: [.command])
    }

    static func commandOption(keyCode: UInt16, key: String) -> Self {
        Self(keyCode: keyCode, key: key, modifiers: [.command, .option])
    }

    static func commandShift(keyCode: UInt16, key: String) -> Self {
        Self(keyCode: keyCode, key: key, modifiers: [.command, .shift])
    }

    init?(event: NSEvent) {
        let modifiers = AppShortcutModifiers.from(event.modifierFlags)
        guard modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control) else {
            return nil
        }
        guard let key = Self.displayKey(for: event), !key.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, key: key, modifiers: modifiers)
    }

    init(keyCode: UInt16, key: String, modifiers: AppShortcutModifiers) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    var displayText: String { modifiers.displayText + key }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && modifiers == .from(event.modifierFlags)
    }

    func hasSameCombination(as other: Self) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    private static func displayKey(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  let character = characters.first,
                  !character.isWhitespace,
                  !character.isNewline else { return nil }
            return String(character).uppercased()
        }
    }
}

enum AppShortcutAssignmentError: LocalizedError, Equatable {
    case conflict(AppShortcutAction)
    case reserved(String)

    var errorDescription: String? {
        switch self {
        case .conflict(let action): "這組快捷鍵已用於「\(action.title)」。"
        case .reserved(let name): "這組快捷鍵保留給 macOS 的「\(name)」，不能覆蓋。"
        }
    }
}

final class AppShortcutStore: ObservableObject {
    static let storageKey = "customKeyboardShortcuts.v1"
    static let fontZoomMigrationKey = "customKeyboardShortcuts.fontZoomDefaults.v1"

    @Published private(set) var assignments: [AppShortcutAction: AppShortcutDefinition]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([AppShortcutAction: AppShortcutDefinition].self, from: data) {
            assignments = decoded
            if !defaults.bool(forKey: Self.fontZoomMigrationKey) {
                for action in AppShortcutAction.allCases where action.fontZoomAction != nil {
                    guard assignments[action] == nil, let shortcut = action.defaultShortcut,
                          conflictingAction(for: shortcut, action: action) == nil else { continue }
                    assignments[action] = shortcut
                }
                persist()
            }
        } else {
            assignments = Self.defaultAssignments
        }
    }

    func shortcut(for action: AppShortcutAction) -> AppShortcutDefinition? {
        assignments[action]
    }

    func action(matching event: NSEvent) -> AppShortcutAction? {
        AppShortcutAction.allCases.first { action in
            guard let assignment = assignments[action] else { return false }
            return action.effectiveShortcuts(for: assignment).contains { $0.matches(event) }
        }
    }

    func isManagedDefault(_ event: NSEvent) -> Bool {
        Self.defaultAssignments.contains { action, shortcut in
            action.effectiveShortcuts(for: shortcut).contains { $0.matches(event) }
        }
    }

    func isFontZoomDefault(_ event: NSEvent) -> Bool {
        Self.defaultAssignments.contains { action, shortcut in
            action.fontZoomAction != nil && action.effectiveShortcuts(for: shortcut).contains { $0.matches(event) }
        }
    }

    func assign(_ shortcut: AppShortcutDefinition?, to action: AppShortcutAction) throws {
        if let shortcut {
            if let reservedName = Self.reservedShortcutName(shortcut) {
                throw AppShortcutAssignmentError.reserved(reservedName)
            }
            if let conflict = conflictingAction(for: shortcut, action: action) {
                throw AppShortcutAssignmentError.conflict(conflict)
            }
            assignments[action] = shortcut
        } else {
            assignments.removeValue(forKey: action)
        }
        persist()
    }

    func reset(_ action: AppShortcutAction) throws {
        try assign(action.defaultShortcut, to: action)
    }

    func resetAll() {
        assignments = Self.defaultAssignments
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        defaults.set(data, forKey: Self.storageKey)
        defaults.set(true, forKey: Self.fontZoomMigrationKey)
    }

    private func conflictingAction(for shortcut: AppShortcutDefinition, action: AppShortcutAction) -> AppShortcutAction? {
        let requested = action.effectiveShortcuts(for: shortcut)
        return AppShortcutAction.allCases.first { existing in
            guard existing != action, let assigned = assignments[existing] else { return false }
            return existing.effectiveShortcuts(for: assigned).contains { combination in
                requested.contains { $0.hasSameCombination(as: combination) }
            }
        }
    }

    private static let defaultAssignments: [AppShortcutAction: AppShortcutDefinition] = {
        Dictionary(uniqueKeysWithValues: AppShortcutAction.allCases.compactMap { action in
            action.defaultShortcut.map { (action, $0) }
        })
    }()

    private static func reservedShortcutName(_ shortcut: AppShortcutDefinition) -> String? {
        guard shortcut.modifiers == [.command] else { return nil }
        return switch shortcut.keyCode {
        case 12: "結束 App（⌘Q）"
        case 4: "隱藏 App（⌘H）"
        case 46: "最小化視窗（⌘M）"
        case 43: "設定（⌘,）"
        default: nil
        }
    }
}
