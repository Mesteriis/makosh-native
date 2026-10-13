import Foundation
import Combine

/// One explicit owner per app, shared by its communication windows.
@MainActor public final class TelegramCallCoordinator: ObservableObject {
    @Published public private(set) var isBusy = false
    private var owner: UUID?
    public init() {}
    func reserve() -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID(); owner = token; isBusy = true; return token
    }
    func release(_ token: UUID) {
        guard owner == token else { return }; owner = nil; isBusy = false
    }
}
