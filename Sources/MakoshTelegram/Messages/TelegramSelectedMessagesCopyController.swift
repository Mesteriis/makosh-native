import Foundation
import Combine
import SwiftSignalKit

struct TelegramSelectedMessagesCopyRequest: Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let revision: UUID
    let contextID: UUID
    let accountID: Int64
    let chatID: Int64
    let sources: [TelegramMessageActionSource]
    init(session: TelegramMessageSelectionSession) {
        id = UUID(); sessionID = session.id; revision = session.revision; contextID = session.contextID
        accountID = session.accountID; chatID = session.chatID; sources = session.sources
    }
}
@MainActor protocol TelegramSelectedMessagesCopyProvider: AnyObject {
    var accountID: Int64 { get }
    func resolve(request: TelegramSelectedMessagesCopyRequest,
                 completion: @escaping @MainActor (String?) -> Void) -> Disposable
}

@MainActor public final class TelegramSelectedMessagesCopyController: ObservableObject {
    @Published public private(set) var isBusy = false
    @Published public private(set) var error: String?
    private var provider: (any TelegramSelectedMessagesCopyProvider)?
    private var token: UUID?
    private let subscription = MetaDisposable()
    private var deadline: Task<Void, Never>?
    public init() {}
    isolated deinit { cancel() }
    func bind(provider: (any TelegramSelectedMessagesCopyProvider)?) { cancel(); self.provider = provider }
    @discardableResult
    func start(request: TelegramSelectedMessagesCopyRequest, isCurrent: @escaping @MainActor () -> Bool,
               receive: @escaping @MainActor (String) -> Void) -> Bool {
        guard !isBusy, let provider, provider.accountID == request.accountID, isCurrent(),
              !request.sources.isEmpty, request.sources.count <= 100 else { return false }
        cancel(); let token = UUID(); self.token = token; isBusy = true
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.token == token else { return }
            self?.timeout()
        }
        let disposable = provider.resolve(request: request) { [weak self] text in
            guard let self, self.token == token else { return }
            self.cancel()
            guard isCurrent() else { return }
            guard let text else { self.error = "Не удалось скопировать выбранные сообщения."; return }
            receive(text)
        }
        if self.token == token { subscription.set(disposable) } else { disposable.dispose() }
        return true
    }
    func timeout() {
        guard isBusy else { return }
        cancel(); error = "Не удалось скопировать выбранные сообщения. Повторите попытку."
    }
    public func cancel() { token = nil; isBusy = false; deadline?.cancel(); deadline = nil; subscription.set(nil); error = nil }
}
