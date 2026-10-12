import SwiftUI

struct SFTPHostOpeningPresentation: ViewModifier {
    @EnvironmentObject private var hostStore: HostStore
    @ObservedObject var controller: SFTPHostOpeningController
    @ObservedObject var connection: SFTPRemoteBrowserStore
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { connection.endingStatus != nil },
                set: { if !$0 { connection.cancelEnding() } }
            )) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("結束 SFTP 編輯").font(.headline)
                    if let status = connection.endingStatus {
                        if status.checking {
                            HStack { ProgressView().controlSize(.small); Text("正在核對與清理已完成的快取…") }
                            Text(status.fileName).lineLimit(2).foregroundStyle(.secondary)
                        } else {
                            Text("以下工作尚未完成，副本將保留。可返回等待回存，或保留副本後關閉連線。")
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(status.issues) { issue in
                                        VStack(alignment: .leading) {
                                            Text(issue.name).fontWeight(.medium)
                                            Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 220)
                        }
                        HStack {
                            Button(status.checking ? "取消結束" : "返回／等待回存", role: .cancel) { connection.cancelEnding() }
                            Spacer()
                            if !status.checking {
                                Button("保留副本並關閉") { connection.preserveAndEnd() }
                            }
                        }
                    }
                }
                .padding(24).frame(width: 470)
                .interactiveDismissDisabled()
            }
            .sheet(item: $controller.usernameHost, onDismiss: {
                controller.usernameDismissed(hosts: hostStore.hosts, connection: connection, show: onOpen)
            }) { host in
                ConnectionUsernameView(host: host, initialUsername: "", isSFTP: true) { username in
                    try controller.submitUsername(username)
                }
            }
            .alert("切換 SFTP 主機？", isPresented: Binding(
                get: { controller.switchConfirmation != nil },
                set: { if !$0 { controller.switchConfirmation = nil } }
            ), presenting: controller.switchConfirmation) { _ in
                Button("取消", role: .cancel) { controller.switchConfirmation = nil }
                Button("切換") {
                    controller.confirmSwitch(hosts: hostStore.hosts, connection: connection, show: onOpen)
                }
            } message: { confirmation in
                Text("將關閉 \(confirmation.previousDescription)，並開啟 \(confirmation.request.host.displayName)（\(confirmation.request.username)@\(confirmation.request.host.hostname):\(confirmation.request.host.port)）。")
            }
            .alert("無法開啟 SFTP", isPresented: Binding(
                get: { controller.notice != nil },
                set: { if !$0 { controller.notice = nil } }
            )) {
                Button("好", role: .cancel) { controller.notice = nil }
            } message: {
                Text(controller.notice ?? "")
            }
    }
}
