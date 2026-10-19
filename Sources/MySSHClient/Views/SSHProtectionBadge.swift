import SwiftUI

struct SSHProtectionBadge: View {
    let value: SSHNegotiatedProtection
    var required = false
    @State private var showingDetails = false
    @State private var capability: SSHCapabilityQueryResult?

    private var symbol: String {
        switch value.status {
        case .postQuantum: "shield.lefthalf.filled"
        case .traditional: "lock"
        case .negotiating: "ellipsis.shield"
        case .unknown, .closed: "questionmark.shield"
        }
    }

    var body: some View {
        Button { showingDetails.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                Label(value.title, systemImage: symbol).fixedSize()
                Image(systemName: symbol)
            }.font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(value.status == .postQuantum ? Color.green : Color.secondary)
        .help(value.title).accessibilityLabel(value.title)
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Text(value.title).font(.headline)
                if let algorithm = value.algorithm {
                    Text(algorithm).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Text(required ? "本次連線要求後量子金鑰交換" : "本次連線沿用主機演算法設定")
                Text("此狀態只說明這個 SSH 通道的金鑰交換，不代表登入簽章或其他連線均具備後量子保護。")
                    .font(.caption).foregroundStyle(.secondary)
                if case .available(let capabilities) = capability {
                    Text(capabilities.postQuantumAlgorithms.isEmpty ? "本機不支援後量子金鑰交換" : "本機支援後量子金鑰交換")
                    Text(capabilities.version).font(.caption).foregroundStyle(.secondary)
                } else { Text(capability == nil ? "正在檢查本機能力…" : "暫時無法檢查本機能力").font(.caption) }
            }
            .padding(16).frame(width: 310, alignment: .leading)
            .task { capability = await SSHCapabilityService.shared.query() }
        }
    }
}
