import AppKit
import Combine
import Sparkle

/// App-wide owner for Sparkle. Keeping one controller alive prevents every
/// SwiftUI window or Settings presentation from creating another updater.
@MainActor
final class AppUpdaterStore: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var canCheckObservation: AnyCancellable?

    let configuration: AppUpdateConfiguration

    init(bundle: Bundle = .main) {
        configuration = AppUpdateConfiguration(bundle: bundle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: configuration.isReady,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        if configuration.isReady {
            canCheckObservation = updaterController.updater
                .publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] value in
                    self?.canCheckForUpdates = value
                }
        } else {
            // The integration-test build deliberately has no production feed
            // or public key yet. Keep the entry point enabled so it can explain
            // that state without letting Sparkle show a configuration error.
            canCheckForUpdates = true
        }
    }

    var statusTitle: String {
        configuration.isReady ? "安全更新已設定" : "更新功能尚未連接正式來源"
    }

    var statusDescription: String {
        if configuration.isReady {
            if configuration.allowsLoopbackHTTP {
                return "MyTerm 更新實驗室只會從這台 Mac 的 127.0.0.1 讀取測試更新，並在安裝前驗證 Sparkle 更新簽章。"
            }
            return "MyTerm 會透過 HTTPS 讀取更新資訊，並在安裝前驗證 Sparkle 更新簽章。"
        }
        return "目前是更新框架整合測試版；正式更新網址與公開驗證金鑰會在下一個安全階段加入。"
    }

    func checkForUpdates() {
        guard configuration.isReady else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "更新功能尚未連接正式來源"
            alert.informativeText = "Sparkle 更新框架已經整合完成，但這個測試版本尚未放入正式更新網址與公開驗證金鑰，因此不會連線或下載任何檔案。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        updaterController.checkForUpdates(nil)
    }
}

struct AppUpdateConfiguration: Equatable {
    let feedURL: URL?
    let publicKey: String?
    let allowsLoopbackHTTP: Bool

    init(bundle: Bundle) {
        if let value = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String {
            feedURL = URL(string: value)
        } else {
            feedURL = nil
        }
        publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        allowsLoopbackHTTP = bundle.object(
            forInfoDictionaryKey: "MyTermUpdateLabMode"
        ) as? Bool == true
    }

    var isReady: Bool {
        guard let feedURL else { return false }
        let scheme = feedURL.scheme?.lowercased()
        let isSecureFeed = scheme == "https"
        let isAllowedLabFeed = allowsLoopbackHTTP
            && scheme == "http"
            && (feedURL.host == "127.0.0.1" || feedURL.host == "localhost")
        guard isSecureFeed || isAllowedLabFeed else { return false }
        return !(publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
