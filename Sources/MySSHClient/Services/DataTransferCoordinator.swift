import Combine
import Foundation

enum DataTransferAction: Equatable {
    case importHosts
    case exportHosts
}

@MainActor
final class DataTransferCoordinator: ObservableObject {
    @Published var requestedAction: DataTransferAction?

    func request(_ action: DataTransferAction) {
        requestedAction = action
    }

    func consume(_ action: DataTransferAction) {
        if requestedAction == action { requestedAction = nil }
    }
}
