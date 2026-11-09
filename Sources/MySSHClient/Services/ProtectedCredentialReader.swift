import Foundation

/// No credential contents are stored here. Synchronous notification delivery
/// records background sync mutations before a main-queue UI callback can run.
final class CredentialChangeTracker {
    private let lock = NSLock()
    private var generations: [UUID: UInt64] = [:]
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(notification: Notification.Name, center: NotificationCenter = .default) {
        self.center = center
        token = center.addObserver(forName: notification, object: nil, queue: nil) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            self?.changed(id)
        }
    }

    private func changed(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        generations[id, default: 0] &+= 1
    }

    func generation(for id: UUID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generations[id, default: 0]
    }

    deinit { if let token { center.removeObserver(token) } }
}

/// A Keychain call already in progress cannot be forcibly interrupted. The
/// request instead cancels work not yet started and discards late results.
final class ProtectedCredentialReadRequest {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    static func start(hostID: UUID, queue: DispatchQueue,
                      load: @escaping (UUID) throws -> Data?,
                      complete: @escaping (Result<Data?, Error>) -> Void) -> ProtectedCredentialReadRequest {
        let request = ProtectedCredentialReadRequest()
        queue.async {
            guard !request.isCancelled else { return }
            let result = Result { try load(hostID) }
            DispatchQueue.main.async {
                if request.isCancelled {
                    if case .success(var data) = result, data != nil { data!.resetBytes(in: data!.indices) }
                    return
                }
                complete(result)
            }
        }
        return request
    }
}
