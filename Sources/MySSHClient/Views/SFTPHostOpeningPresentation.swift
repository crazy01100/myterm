import SwiftUI

struct SFTPHostOpeningPresentation: ViewModifier {
    @EnvironmentObject private var hostStore: HostStore
    @ObservedObject var controller: SFTPHostOpeningController
    let connection: SFTPRemoteBrowserStore
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        content
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
