import SwiftUI
import UniformTypeIdentifiers

struct HostEditorView: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: HostProfile
    @State private var password = ""
    @State private var showingKeyPicker = false
    @State private var errorMessage: String?
    private let isNew: Bool

    init(profile: HostProfile?, defaultGroupID: UUID? = nil) {
        isNew = profile == nil
        var initialProfile = profile ?? HostProfile()
        if profile == nil { initialProfile.groupID = defaultGroupID }
        _profile = State(initialValue: initialProfile)
    }

    private var hasDefaultUsername: Bool {
        !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新增主機" : "編輯主機")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()

            Form {
                Section("主機") {
                    TextField("名稱（選填，空白時顯示主機位址）", text: $profile.name)
                    TextField("主機位址或 IP", text: $profile.hostname)
                    TextField("連接埠", value: $profile.port, format: .number)
                    TextField("預設使用者名稱（選填）", text: $profile.username)
                    Picker("群組", selection: $profile.groupID) {
                        Text("未分類").tag(Optional<UUID>.none)
                        ForEach(store.groupChoices()) { choice in
                            Text(choice.path).tag(Optional(choice.id))
                        }
                    }
                    TextField("備註", text: $profile.notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("驗證") {
                    Picker("驗證方式", selection: $profile.authenticationMethod) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    if profile.authenticationMethod == .password {
                        if hasDefaultUsername {
                            SecureField(
                                KeychainStore.containsPassword(for: profile.id) ? "輸入新密碼；留空保留原密碼" : "密碼",
                                text: $password
                            )
                            Text("密碼只會寫入 macOS Keychain，並綁定預設使用者。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("未設定預設使用者時，連線時輸入本次帳號與密碼；不會自動套用其他帳號的密碼。", systemImage: "key.horizontal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if profile.authenticationMethod == .privateKey {
                        HStack {
                            TextField("私鑰檔案", text: $profile.privateKeyPath)
                            Button("選擇…") { showingKeyPicker = true }
                        }
                    }
                }

                Section("連線演算法") {
                    Picker("模式", selection: $profile.algorithmMode) {
                        ForEach(AlgorithmMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    if profile.algorithmMode == .rsaCompatibility {
                        Label("只對這台主機額外允許 ssh-rsa。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if profile.algorithmMode == .custom {
                        Label("自訂或舊式演算法可能降低連線安全性，只應用於已知設備。", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                        TextField("Host Key Algorithms", text: $profile.customAlgorithms.hostKeyAlgorithms)
                        TextField("Public Key Algorithms", text: $profile.customAlgorithms.publicKeyAlgorithms)
                        TextField("Key Exchange Algorithms", text: $profile.customAlgorithms.keyExchangeAlgorithms)
                        TextField("Ciphers", text: $profile.customAlgorithms.ciphers)
                        Text("可使用逗號分隔；前置 + 代表加入系統預設清單，例如 +ssh-rsa。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 580, height: 700)
        .onChange(of: profile.username) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { password = "" }
        }
        .fileImporter(
            isPresented: $showingKeyPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                profile.privateKeyPath = url.path
            }
        }
    }

    private func save() {
        do {
            try store.save(profile, password: password.isEmpty ? nil : password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
