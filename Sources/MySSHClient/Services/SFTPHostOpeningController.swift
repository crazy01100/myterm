import Combine
import Foundation

/// Connection identity excludes presentation metadata and all secret values.
struct SFTPConnectionTarget: Equatable {
    let hostID: UUID
    let hostname: String
    let port: Int
    let username: String
    let savedUsername: String
    let authentication: AuthenticationMethod
    let privateKeyPath: String
    let algorithmMode: AlgorithmMode
    let algorithms: CustomAlgorithms

    init(host: HostProfile, username: String) {
        hostID = host.id
        hostname = host.hostname
        port = host.port
        self.username = username
        savedUsername = host.username
        authentication = host.authenticationMethod
        privateKeyPath = host.privateKeyPath
        algorithmMode = host.algorithmMode
        algorithms = host.customAlgorithms
    }
}

struct SFTPConnectionSnapshot {
    let target: SFTPConnectionTarget?
    let generation: UUID
    let isBusy: Bool
    let description: String
}

@MainActor
protocol SFTPHostOpeningConnection: AnyObject {
    var openingSnapshot: SFTPConnectionSnapshot { get }
    func connect(to host: HostProfile, username: String)
}

/// Coordinates only saved-host opening. All decisions and the final connect
/// happen synchronously on the main actor, with fresh inventory/connection state.
@MainActor
final class SFTPHostOpeningController: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let host: HostProfile
        let username: String
        var target: SFTPConnectionTarget { SFTPConnectionTarget(host: host, username: username) }
    }
    struct SwitchConfirmation {
        let request: Request
        let previousGeneration: UUID
        let previousTarget: SFTPConnectionTarget?
        let previousDescription: String
    }

    @Published var usernameHost: HostProfile?
    @Published var switchConfirmation: SwitchConfirmation?
    @Published var notice: String?
    private var submittedUsername: Request?

    func begin(host: HostProfile, hosts: [HostProfile], connection: SFTPHostOpeningConnection, show: () -> Void) {
        guard usernameHost == nil, switchConfirmation == nil, notice == nil else { return }
        guard let latest = hosts.first(where: { $0.id == host.id }) else {
            notice = "這台主機已不存在，請重新選擇。"
            return
        }
        guard SFTPConnectionTarget(host: latest, username: latest.username) ==
                SFTPConnectionTarget(host: host, username: host.username) else {
            notice = "主機連線設定已變更，請重新選擇。"
            return
        }
        if latest.username.isEmpty {
            submittedUsername = nil
            usernameHost = latest
        } else {
            open(Request(host: latest, username: latest.username), hosts: hosts, connection: connection, show: show)
        }
    }

    func submitUsername(_ username: String) throws {
        guard let host = usernameHost else { return }
        submittedUsername = Request(host: host, username: try HostProfile.validatedUsername(username))
    }

    /// Called after the username sheet has dismissed, so a switch confirmation
    /// never competes with that sheet. Cancellation has no connection side effect.
    func usernameDismissed(hosts: [HostProfile], connection: SFTPHostOpeningConnection, show: () -> Void) {
        usernameHost = nil
        let request = submittedUsername
        submittedUsername = nil
        if let request { open(request, hosts: hosts, connection: connection, show: show) }
    }

    func confirmSwitch(hosts: [HostProfile], connection: SFTPHostOpeningConnection, show: () -> Void) {
        guard let confirmation = switchConfirmation else { return }
        switchConfirmation = nil
        let current = connection.openingSnapshot
        guard current.generation == confirmation.previousGeneration,
              current.target == confirmation.previousTarget else {
            notice = "目前 SFTP 連線已變更，請重新選擇要開啟的主機。"
            return
        }
        open(confirmation.request, hosts: hosts, connection: connection, confirmed: true, show: show)
    }

    private func open(_ request: Request, hosts: [HostProfile], connection: SFTPHostOpeningConnection,
                      confirmed: Bool = false, show: () -> Void) {
        guard let host = hosts.first(where: { $0.id == request.host.id }) else {
            notice = "這台主機已不存在，請重新選擇。"
            return
        }
        guard SFTPConnectionTarget(host: host, username: request.username) == request.target else {
            notice = "主機連線設定已變更，請重新選擇。"
            return
        }
        do {
            _ = try host.validated()
            _ = try HostProfile.validatedUsername(request.username)
        } catch {
            notice = error.localizedDescription
            return
        }
        let current = connection.openingSnapshot
        if current.target == request.target {
            show()
            return
        }
        guard !current.isBusy else {
            notice = "SFTP 仍有傳輸或檔案操作尚未完成。請先完成目前操作，再開啟其他主機。"
            return
        }
        if current.target != nil && !confirmed {
            switchConfirmation = SwitchConfirmation(request: request,
                previousGeneration: current.generation, previousTarget: current.target,
                previousDescription: current.description)
            return
        }
        connection.connect(to: host, username: request.username)
        show()
    }
}
