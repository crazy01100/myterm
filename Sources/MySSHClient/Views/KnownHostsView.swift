import SwiftUI

struct KnownHostsView: View {
    let onReturnToHosts: () -> Void

    @EnvironmentObject private var knownHostsStore: KnownHostsStore
    @State private var searchText = ""

    private var filteredRecords: [KnownHostRecord] {
        guard !searchText.isEmpty else { return knownHostsStore.records }
        return knownHostsStore.records.filter {
            $0.displayHost.localizedCaseInsensitiveContains(searchText) ||
            $0.keyType.localizedCaseInsensitiveContains(searchText) ||
            $0.fingerprint.localizedCaseInsensitiveContains(searchText) ||
            $0.comment.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(AppVisualTheme.contentBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("返回主機", systemImage: "arrow.left", action: onReturnToHosts)
                .buttonStyle(.bordered)
                .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text("Known Hosts").font(.title2.weight(.semibold))
                Text(summaryText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋主機或指紋", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 220)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppVisualTheme.subtleSurface, in: .rect(cornerRadius: 8))

            Button {
                do { try knownHostsStore.syncFromSystem() }
                catch { knownHostsStore.lastError = error.localizedDescription }
            } label: {
                Label(knownHostsStore.lastSyncedAt == nil ? "載入" : "同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!knownHostsStore.sourceExists)
            .help("只有按下此按鈕時才讀取 ~/.ssh/known_hosts")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(AppVisualTheme.raisedSurface)
    }

    @ViewBuilder
    private var content: some View {
        if knownHostsStore.records.isEmpty {
            ContentUnavailableView {
                Label("尚未載入 Known Hosts", systemImage: "checkmark.shield")
            } description: {
                Text(knownHostsStore.sourceExists
                     ? "按下「載入」才會讀取 ~/.ssh/known_hosts；MyTerm 不會在背景自動同步。"
                     : "找不到 ~/.ssh/known_hosts。建立該檔案後可回到這裡手動載入。")
            } actions: {
                if knownHostsStore.sourceExists {
                    Button("載入 Known Hosts") {
                        do { try knownHostsStore.syncFromSystem() }
                        catch { knownHostsStore.lastError = error.localizedDescription }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredRecords) { record in
                HStack(spacing: 12) {
                    Image(systemName: record.isHashed ? "number.square" : "checkmark.shield.fill")
                        .foregroundStyle(record.marker == "@revoked" ? Color.red : Color.accentColor)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(record.displayHost).font(.headline)
                            if let marker = record.marker {
                                Text(marker).font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(AppVisualTheme.subtleSurface, in: .capsule)
                            }
                        }
                        Text("\(record.keyType)  ·  \(record.fingerprint)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 5)
                .listRowBackground(AppVisualTheme.raisedSurface)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(AppVisualTheme.contentBackground)
        }
    }

    private var summaryText: String {
        guard let date = knownHostsStore.lastSyncedAt else { return "獨立保存 · 尚未載入" }
        return "\(knownHostsStore.records.count) 筆 · 上次同步 \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
