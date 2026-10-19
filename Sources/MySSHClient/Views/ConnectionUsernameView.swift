import SwiftUI

struct ConnectionUsernameView: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile
    let isSFTP: Bool
    let onConnect: (String) async throws -> Void
    @State private var username: String
    @State private var errorMessage: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isConnecting = false

    init(host: HostProfile, initialUsername: String, isSFTP: Bool = false, onConnect: @escaping (String) async throws -> Void) {
        self.host = host
        self.isSFTP = isSFTP
        self.onConnect = onConnect
        _username = State(initialValue: initialUsername)
    }

    private var isDefaultAccount: Bool {
        !host.username.isEmpty && username.trimmingCharacters(in: .whitespacesAndNewlines) == host.username
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("選擇連線帳號").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName).font(.headline)
                Text("\(host.hostname):\(host.port)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            TextField("本次使用者名稱", text: $username)
                .textFieldStyle(.roundedBorder)
                .disabled(isConnecting)
            if host.authenticationMethod == .password {
                Text(isSFTP ? "SFTP 使用這台主機已儲存的密碼；若尚未保存密碼，請先透過 SSH 連線保存，或改用私鑰／SSH Agent。" : isDefaultAccount
                     ? "將使用這台主機在本機加密保管庫中儲存的預設帳號密碼。"
                     : "其他帳號不會套用預設帳號的密碼；請在終端提示時輸入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("這次輸入不會修改已儲存的主機資料。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { connectionTask?.cancel(); dismiss() }
                Button(isConnecting ? "準備連線…" : "連線") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onDisappear { connectionTask?.cancel() }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        connectionTask = Task { @MainActor in
            defer { isConnecting = false; connectionTask = nil }
            do {
                try Task.checkCancellation()
                let username = try HostProfile.validatedUsername(username)
                try await onConnect(username)
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
