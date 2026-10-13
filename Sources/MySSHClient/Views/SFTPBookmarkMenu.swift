import SwiftUI

struct SFTPBookmarkMenu: View {
    @EnvironmentObject private var store: SFTPBookmarkStore
    let isLocal: Bool
    let target: SFTPBookmarkTarget?
    let path: String
    let canNavigate: Bool
    let onOpen: (String) -> Void
    @State private var showingManager = false
    @State private var adding: BookmarkEditorRequest?

    private var duplicate: Bool {
        isLocal ? store.localBookmarks.contains { $0.path == path }
            : store.bookmarks.contains { $0.path == path && $0.target == target && !store.needsReview($0.id) }
    }
    var body: some View {
        Menu {
            if let target { Text("\(target.username)@\(target.hostname):\(target.port)") }
            Button(duplicate ? "目前目錄已加入書籤" : "將目前目錄加入書籤…", systemImage: "bookmark.badge.plus") {
                adding = .init(path: path, target: target, scope: store.activeScope)
            }
            .disabled(duplicate || !canNavigate || store.loadError != nil)
            Divider()
            if isLocal {
                ForEach(store.localBookmarks) { bookmark in
                    Button(bookmark.title) { onOpen(bookmark.path) }
                        .disabled(!canNavigate)
                }
            } else {
                ForEach(store.bookmarks.filter { $0.target == target && !store.needsReview($0.id) }) { bookmark in
                    Button(bookmark.title) { onOpen(bookmark.path) }
                        .disabled(!canNavigate)
                }
            }
            Divider()
            Button("管理書籤…", systemImage: "bookmark") { showingManager = true }
        } label: {
            Image(systemName: "bookmark").frame(width: 26, height: 28).contentShape(.rect)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(canNavigate ? "目錄書籤" : "目前工作完成後即可跳轉書籤")
        .accessibilityLabel(isLocal ? "本機目錄書籤" : "遠端目錄書籤")
        .sheet(item: $adding) { request in
            BookmarkEditor(request: request, isLocal: isLocal) {
                canNavigate && path == request.path && (isLocal || target == request.target)
            }
        }
        .sheet(isPresented: $showingManager) { SFTPBookmarkManager(isLocal: isLocal) }
    }
}

private struct BookmarkEditorRequest: Identifiable {
    let id = UUID()
    let path: String
    let target: SFTPBookmarkTarget?
    let scope: String
    var localOriginal: LocalDirectoryBookmark?
    var remoteOriginal: RemoteDirectoryBookmark?
    var initialTitle: String {
        localOriginal?.title ?? remoteOriginal?.title ?? (path == "/" ? "根目錄" : (path as NSString).lastPathComponent)
    }
}

private struct BookmarkEditor: View {
    @EnvironmentObject private var store: SFTPBookmarkStore
    @Environment(\.dismiss) private var dismiss
    let request: BookmarkEditorRequest
    let isLocal: Bool
    var canSaveNew: () -> Bool = { true }
    @State private var title = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("目錄書籤").font(.headline)
            TextField("名稱", text: $title)
            if let target = request.target {
                Text("\(target.username)@\(target.hostname):\(target.port)").foregroundStyle(.secondary)
            }
            Text(request.path).textSelection(.enabled).font(.callout).lineLimit(4)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 450)
        .onAppear { title = request.initialTitle }
    }
    private func save() {
        do {
            if request.localOriginal == nil && request.remoteOriginal == nil {
                guard canSaveNew() else { throw BookmarkError.changed }
            }
            if isLocal {
                var value = request.localOriginal ?? LocalDirectoryBookmark(title: title, path: request.path)
                value.title = title
                try store.saveLocal(value, original: request.localOriginal)
            } else {
                guard let target = request.target else { throw BookmarkError.changed }
                var value = request.remoteOriginal ?? RemoteDirectoryBookmark(title: title, path: request.path, target: target)
                value.title = title
                try store.saveEdited(value, original: request.remoteOriginal, scope: request.scope)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private enum BookmarkRemovalRequest: Identifiable {
    case local(LocalDirectoryBookmark)
    case remote(RemoteDirectoryBookmark, scope: String, candidate: Bool)

    var id: UUID {
        switch self {
        case .local(let value): return value.id
        case .remote(let value, _, _): return value.id
        }
    }

    var title: String {
        if case .remote(_, _, true) = self { return "捨棄候選？" }
        return "移除書籤？"
    }

    var actionTitle: String {
        if case .remote(_, _, true) = self { return "捨棄候選" }
        return "移除書籤"
    }

    var bookmarkTitle: String {
        switch self {
        case .local(let value): return value.title
        case .remote(let value, _, _): return value.title
        }
    }

    var detail: String {
        switch self {
        case .local(let value):
            return value.path
        case .remote(let value, _, _):
            return "\(value.target.username)@\(value.target.hostname):\(value.target.port)\n\(value.path)"
        }
    }
}

private struct SFTPBookmarkManager: View {
    @EnvironmentObject private var store: SFTPBookmarkStore
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss
    let isLocal: Bool
    @State private var editing: BookmarkEditorRequest?
    @State private var removing: BookmarkRemovalRequest?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isLocal ? "本機目錄書籤" : "遠端目錄書籤").font(.headline)
            Text(isLocal ? "只保存在這台 Mac" : store.syncMessage).font(.callout).foregroundStyle(.secondary)
            if let message = error ?? store.loadError { Text(message).font(.callout).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isLocal {
                        ForEach(store.localBookmarks) { value in
                            row(title: value.title, detail: value.path) {
                                Button("重新命名") { editing = .init(path: value.path, target: nil, scope: store.activeScope, localOriginal: value) }
                                Button("移除", role: .destructive) { removing = .local(value) }
                            }
                        }
                    } else {
                        ForEach(store.bookmarks) { value in
                            let scope = store.activeScope
                            row(title: value.title, detail: remoteDetail(value)) {
                                if store.needsReview(value.id) {
                                    Text("待確認候選").foregroundStyle(.orange)
                                    Button("使用此名稱") { perform { try store.resolve(value, scope: scope) } }
                                    Button("捨棄候選") { removing = .remote(value, scope: scope, candidate: true) }
                                } else {
                                    Button("重新命名") { editing = .init(path: value.path, target: value.target, scope: scope, remoteOriginal: value) }
                                    Button("移除", role: .destructive) { removing = .remote(value, scope: scope, candidate: false) }
                                }
                            }
                        }
                    }
                    if isLocal ? store.localBookmarks.isEmpty : store.bookmarks.isEmpty {
                        Text("尚未加入目錄書籤").foregroundStyle(.secondary).padding()
                    }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 620, height: 460)
        .sheet(item: $editing) { BookmarkEditor(request: $0, isLocal: isLocal) }
        .sheet(item: $removing) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text(request.title).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.bookmarkTitle).font(.title3.weight(.semibold))
                        Text(request.detail).font(.body).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button("取消", role: .cancel) { removing = nil }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(BookmarkConfirmationButtonStyle(isDestructive: false))
                    Button(request.actionTitle, role: .destructive) {
                        perform {
                            switch request {
                            case .local(let value): try store.deleteLocal(value)
                            case .remote(let value, let scope, _): try store.deleteRemote(value, scope: scope)
                            }
                        }
                        removing = nil
                    }
                    .buttonStyle(BookmarkConfirmationButtonStyle(isDestructive: true))
                    Spacer(minLength: 0)
                }
            }
            .padding(20).frame(width: 320)
            .onExitCommand { removing = nil }
        }
    }
    private func row<Actions: View>(title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { actions() }.buttonStyle(.borderless)
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func remoteDetail(_ value: RemoteDirectoryBookmark) -> String {
        let host = hosts.hosts.first { $0.id == value.target.hostID && $0.hostname == value.target.hostname && $0.port == value.target.port }
        return "\(host?.displayName ?? "原主機不可用") · \(value.target.username)@\(value.target.hostname):\(value.target.port)\n\(value.path)"
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct BookmarkConfirmationButtonStyle: ButtonStyle {
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(width: 100)
            .padding(.vertical, 6)
            .foregroundStyle(isDestructive ? Color(nsColor: .systemRed) : .primary)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(isDestructive ? Color(nsColor: .systemRed).opacity(0.15) : Color.primary.opacity(0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
