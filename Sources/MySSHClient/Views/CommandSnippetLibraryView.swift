import AppKit
import SwiftUI

struct CommandSnippetLibraryView: View {
    @ObservedObject var store: CommandSnippetStore
    @EnvironmentObject private var syncSettings: SyncSettingsStore
    let target: SnippetTargetIdentity?
    let targetName: String
    let targetSession: TerminalSession?
    let currentSessionID: UUID?
    let onInsert: (CommandSnippet) throws -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editor: CommandSnippet?
    @State private var editorOriginal: CommandSnippet?
    @State private var editorScope = "local"
    @State private var deletionScope = "local"
    @State private var deleting: CommandSnippet?
    @State private var errorMessage: String?
    @State private var copied = false

    private var matches: [CommandSnippet] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.snippets.filter { text.isEmpty || "\($0.title) \($0.command) \($0.category) \($0.note)".localizedCaseInsensitiveContains(text) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var selected: CommandSnippet? { matches.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("常用指令庫", systemImage: "curlybraces").font(.headline)
                Spacer()
                Button { editorOriginal = nil; editorScope = store.activeScope; editor = CommandSnippet(title: "", command: "") } label: { Image(systemName: "plus") }
                    .help("新增指令").accessibilityLabel("新增指令").disabled(store.loadError != nil)
                Button(action: onClose) { Image(systemName: "xmark") }.help("關閉指令庫").accessibilityLabel("關閉指令庫")
            }.buttonStyle(.borderless).padding(14)
            Text(syncSettings.metadataSyncEnabled ? store.syncMessage : "保存在這台 Mac；同步已關閉。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            TextField("搜尋名稱、指令或分類", text: $query).textFieldStyle(.roundedBorder).padding(14)
            if let loadError = store.loadError {
                Text(loadError).font(.callout).foregroundStyle(.red).padding(.horizontal, 14)
                Button("重新讀取", action: store.reload).padding(14)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    if matches.isEmpty {
                        Text(store.snippets.isEmpty ? "尚無指令，按右上角 ＋ 新增。" : "沒有符合的指令")
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                    ForEach(matches) { snippet in
                        Button { selection = snippet.id; copied = false } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snippet.title).lineLimit(1)
                                Text(snippet.category.isEmpty ? snippet.command : snippet.category)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .background(selection == snippet.id ? AppVisualTheme.selectedSurface : .clear, in: .rect(cornerRadius: 8))
                    }
                }.padding(.horizontal, 8)
            }.frame(minHeight: 100)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("填入目標").font(.caption).foregroundStyle(.secondary)
                        Text(targetName).font(.callout).lineLimit(3).textSelection(.enabled)
                    }
                }
                if let selected {
                    HStack {
                        Text(selected.title).font(.headline).lineLimit(2)
                        Spacer()
                        Button { editorOriginal = selected; editorScope = store.activeScope; editor = selected } label: { Image(systemName: "pencil") }.accessibilityLabel("編輯指令")
                        Button { deletionScope = store.activeScope; deleting = selected } label: { Image(systemName: "trash") }.accessibilityLabel("刪除指令")
                    }.buttonStyle(.borderless).disabled(store.loadError != nil)
                    ScrollView {
                        Text(selected.command).font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10)
                    }.frame(height: 90).background(AppVisualTheme.contentBackground, in: .rect(cornerRadius: 8))
                    if !selected.note.isEmpty { Text(selected.note).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if store.needsReview(selected.id) {
                        Text("衝突副本尚未同步，請確認內容後保留，或刪除這份副本。").font(.caption).foregroundStyle(.orange)
                        Button("保留並同步") {
                            do { try store.approveConflict(selected.id) } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    HStack {
                        if let targetSession {
                            SnippetInsertButton(session: targetSession, target: target, currentSessionID: currentSessionID,
                                                snippet: selected) { insert(selected) }
                        } else { Button("填入終端") {}.disabled(true) }
                        Button(copied ? "已複製" : "複製") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selected.command, forType: .string)
                            copied = true
                        }
                    }
                    Text(selected.canInsert ? "確認終端可接收指令；填入後自行按 Enter 執行，不會清除已有輸入。" : "多行或含控制字元的內容僅提供複製。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("選取指令以預覽內容").foregroundStyle(.secondary).font(.callout) }
            }.padding(14)
        }
        .frame(width: 320)
        .background(AppVisualTheme.raisedSurface)
        .onChange(of: store.activeScope) { _, _ in selection = nil; copied = false }
        .sheet(item: $editor) { snippet in
            CommandSnippetEditor(snippet: snippet) { value in
                try store.saveEdited(value, original: editorOriginal, scope: editorScope)
                query = ""; selection = value.id; copied = false
            }
        }
        .confirmationDialog("刪除這筆指令？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("刪除", role: .destructive) {
                guard let deleting else { return }
                do {
                    guard deletionScope == store.activeScope, store.snippets.first(where: { $0.id == deleting.id }) == deleting else { throw SnippetSyncError.changed }
                    try store.delete(deleting.id); selection = nil
                }
                catch { errorMessage = error.localizedDescription }
                self.deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
        .alert("無法填入或保存指令", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func insert(_ snippet: CommandSnippet) {
        do { try onInsert(snippet) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct SnippetInsertButton: View {
    @ObservedObject var session: TerminalSession
    let target: SnippetTargetIdentity?
    let currentSessionID: UUID?
    let snippet: CommandSnippet
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Button("填入終端", action: action).buttonStyle(.borderedProminent)
                .disabled(!snippet.canInsert || target?.sessionID != currentSessionID
                          || target?.sessionID != session.id || target?.attemptID != session.inputAttemptID
                          || !session.canReceiveSnippet)
                .help("填入目前選取的窗格；重連後請重新點選窗格。")
        }
    }
}

private struct CommandSnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: CommandSnippet
    let save: (CommandSnippet) throws -> Void
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("編輯常用指令").font(.headline)
            TextField("名稱", text: $snippet.title)
            TextField("分類（選填）", text: $snippet.category)
            Text("指令").font(.callout)
            TextEditor(text: $snippet.command).font(.system(.body, design: .monospaced)).frame(height: 150)
                .border(AppVisualTheme.separator).accessibilityLabel("指令內容")
            TextField("說明（選填）", text: $snippet.note)
            Text("請勿將密碼或 Token 存入指令；開啟跨裝置同步時，指令也會端對端加密同步。").font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存") {
                    do { try save(snippet); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                }.keyboardShortcut("s", modifiers: .command)
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 490)
    }
}

struct SnippetLibraryMenuKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openSnippetLibrary: (() -> Void)? {
        get { self[SnippetLibraryMenuKey.self] }
        set { self[SnippetLibraryMenuKey.self] = newValue }
    }
}
struct SnippetLibraryCommands: Commands {
    @FocusedValue(\.openSnippetLibrary) private var open
    @ObservedObject var shortcuts: AppShortcutStore
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("常用指令庫…" + (shortcuts.shortcut(for: .openSnippetLibrary).map { "　" + $0.displayText } ?? "")) { open?() }
                .disabled(open == nil)
        }
    }
}
