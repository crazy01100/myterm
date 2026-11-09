import Foundation
import LocalAuthentication

enum LocalUserAuthenticationError: Error {
    case cancelled
    case unavailable
    case denied

    var message: String? {
        switch self {
        case .cancelled: nil
        case .unavailable: "目前無法使用 macOS 身分驗證，請稍後再試。"
        case .denied: "未能完成身分驗證，登入資訊仍保持鎖定。"
        }
    }
}

@MainActor
protocol LocalUserAuthenticating: AnyObject {
    func authenticate(_ completion: @escaping (Result<Void, LocalUserAuthenticationError>) -> Void)
    func cancel()
}

@MainActor
final class LocalUserAuthentication: LocalUserAuthenticating {
    private var context: LAContext?
    private var requestID: UUID?

    func authenticate(_ completion: @escaping (Result<Void, LocalUserAuthenticationError>) -> Void) {
        cancel()
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        // Fresh context for every page unlock. Do not enable Touch ID reuse.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            context.invalidate()
            completion(.failure(.unavailable))
            return
        }
        self.context = context
        let requestID = UUID()
        self.requestID = requestID
        context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "查看或複製已儲存的主機登入密碼") { [weak self] success, error in
            let code = (error as? LAError)?.code
            let result: Result<Void, LocalUserAuthenticationError>
            if success { result = .success(()) }
            else if code == .userCancel || code == .appCancel || code == .systemCancel {
                result = .failure(.cancelled)
            } else { result = .failure(.denied) }
            DispatchQueue.main.async {
                guard let self, self.requestID == requestID, let context = self.context else { return }
                self.requestID = nil
                self.context = nil
                context.invalidate()
                completion(result)
            }
        }
    }

    func cancel() {
        let previous = context
        context = nil
        requestID = nil
        previous?.invalidate()
    }
}
