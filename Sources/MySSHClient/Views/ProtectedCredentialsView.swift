import AppKit
import Combine
import SwiftUI

struct ProtectedCredentialsView: View {
    @EnvironmentObject private var hostStore: HostStore
    let isActive: Bool
    @StateObject private var store = ProtectedCredentialsLiveSource.makeStore()
    @State private var subscriptions: [AnyCancellable] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登入資訊").font(.title2.bold())
                    Text("查看與複製已儲存的主機登入密碼")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if store.isUnlocked {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜尋主機、位址或帳號", text: Binding(
                            get: { store.searchText }, set: { store.setSearchText($0) }))
                            .textFieldStyle(.plain)
                            .accessibilityLabel("搜尋登入資訊")
                    }
                    .padding(8)
                    .frame(maxWidth: 280)
                    .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 8))
                    Button("鎖定", systemImage: "lock") { store.lock(clearClipboard: true) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(AppVisualTheme.raisedSurface)
            Divider()
            if store.isUnlocked {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        hostList.frame(width: min(360, max(240, geometry.size.width * 0.32)))
                        Divider()
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                lockedContent
            }
        }
        .background(AppVisualTheme.contentBackground)
        .tint(AppVisualTheme.accent)
        .background(ProtectedCredentialsWindowObserver(store: store))
        .onAppear {
            if subscriptions.isEmpty { subscriptions = ProtectedCredentialsLiveSource.bind(store, to: hostStore) }
            store.setVisible(isActive)
        }
        .onChange(of: isActive) { _, active in store.setVisible(active) }
        .onDisappear {
            store.setVisible(false)
            subscriptions.removeAll()
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 32)).foregroundStyle(AppVisualTheme.accent)
            Text("登入資訊已鎖定").font(.title3.bold())
            Text("使用 macOS 身分驗證後，即可查看或複製已儲存的登入密碼。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if store.isAuthenticating {
                HStack { ProgressView().controlSize(.small); Text("等待系統驗證…") }
                Button("取消") { store.lock() }
            } else {
                Button("解鎖", systemImage: "lock.open") { store.unlock() }
                    .buttonStyle(.borderedProminent)
            }
            if let message = store.message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(store.visibleHosts.count) 台主機").font(.caption).foregroundStyle(.secondary).padding(16)
            if store.visibleHosts.isEmpty {
                Text(store.searchText.isEmpty ? "尚未新增主機" : "找不到符合的主機")
                    .foregroundStyle(.secondary).padding(16)
                Spacer()
            } else {
                List(selection: Binding<UUID?>(
                    get: { store.selectedHost?.id },
                    set: { if let id = $0 { store.select(hostID: id) } else { store.deselect() } }
                )) {
                    ForEach(store.visibleHosts) { host in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(host.displayName).fontWeight(.medium).lineLimit(1)
                            Text(host.addressDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(host.authenticationMethod.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .tag(host.id)
                        .help(host.displayName + "\n" + host.addressDescription)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppVisualTheme.raisedSurface)
    }

    @ViewBuilder private var detail: some View {
        if let host = store.selectedHost {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(host.displayName).font(.title3.bold()).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                        metadataRow("位址", value: "\(host.hostname):\(host.port)", field: .address)
                        metadataRow("帳號", value: host.username.isEmpty ? "未指定" : host.username,
                                    field: host.username.isEmpty ? nil : .account)
                        GridRow { Text("驗證方式").foregroundStyle(.secondary); Text(host.authenticationMethod.title) }
                    }
                    Divider()
                    if host.authenticationMethod != .password {
                        Text("此驗證方式不提供登入密碼查看。")
                            .foregroundStyle(.secondary)
                    } else if host.username.isEmpty {
                        Text("請先在主機設定指定登入帳號，再取用已儲存的密碼。")
                            .foregroundStyle(.secondary)
                    } else {
                        passwordDetail
                    }
                    if let message = store.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "key").font(.title2).foregroundStyle(.secondary)
                Text("選擇一台主機").font(.headline)
                Text("密碼僅在你按下顯示或複製時讀取。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var passwordDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登入密碼").font(.headline)
            if store.passwordIsMissing {
                Text("未儲存").foregroundStyle(.secondary)
            } else {
                Text(store.revealedPassword ?? "••••••••")
                    .font(.body.monospaced()).textSelection(.disabled).privacySensitive()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(store.revealedPassword.map { "登入密碼：\($0)" } ?? "密碼已隱藏")
            }
            HStack(spacing: 12) {
                Button(store.revealedPassword == nil ? "顯示密碼" : "隱藏密碼",
                       systemImage: store.revealedPassword == nil ? "eye" : "eye.slash") {
                    if store.revealedPassword == nil { store.reveal() } else { store.hidePassword() }
                }
                Button("複製密碼", systemImage: "doc.on.doc") { store.copyPassword() }
                if store.isReading { ProgressView().controlSize(.small).accessibilityLabel("正在讀取登入密碼") }
            }
            .buttonStyle(.bordered)
            .disabled(store.isReading)
            Text("顯示與複製的密碼最多保留 30 秒。離開本頁會鎖定，已複製的內容仍可在期限內貼上。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func metadataRow(_ label: String, value: String, field: ProtectedCredentialsStore.MetadataField?) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let field {
                    Button {
                        guard let value = store.metadataForCopy(field) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("複製" + label)
                    .accessibilityLabel("複製" + label)
                }
            }
        }
    }
}
