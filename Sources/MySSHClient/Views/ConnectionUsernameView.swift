import SwiftUI

struct ConnectionUsernameView: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile
    let isSFTP: Bool
    let onConnect: (String) throws -> Void
    @State private var username: String
    @State private var errorMessage: String?

    init(host: HostProfile, initialUsername: String, isSFTP: Bool = false, onConnect: @escaping (String) throws -> Void) {
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
                Button("取消") { dismiss() }
                Button("連線") { connect() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func connect() {
        do {
            let username = try HostProfile.validatedUsername(username)
            try onConnect(username)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
