import Foundation
import Combine

struct TelegramSavedMessagesForwardOrigin: Codable, Equatable, Sendable {
    let chatID: Int64
    let revision: UUID
    let intentID: UUID
}
struct TelegramSavedMessagesForwardRequest: Codable, Equatable, Sendable {
    let id: UUID
    let contextID: UUID
    let accountID: Int64
    let sources: [TelegramComposerForwardSource]
    let origin: TelegramSavedMessagesForwardOrigin?
    init(contextID: UUID, accountID: Int64, sources: [TelegramComposerForwardSource], origin: TelegramSavedMessagesForwardOrigin? = nil) {
        id = UUID(); self.contextID = contextID; self.accountID = accountID; self.sources = sources
        self.origin = origin
    }
    var destinationChatID: Int64 {
        #if DEBUG
        // -1 identifies the offline account, but is not a valid native PeerId.
        // Its owned Postbox reserves 10000 for the synthetic Saved queue.
        if accountID == -1 { return 10000 }
        #endif
        return accountID
    }
    var draft: TelegramComposerDraft {
        .init(accountID: accountID, chatID: destinationChatID, input: .empty, revision: id,
              forwardIntent: .init(id: id, sources: sources))
    }
    var isValid: Bool {
        draft.isValid && sources.allSatisfy { $0.chatID == sources.first?.chatID } && (origin.map { $0.chatID > 0 } ?? true)
    }
}

@MainActor protocol TelegramSavedMessagesForwardProvider: AnyObject {
    var accountID: Int64 { get }
    func recover(completion: @escaping @MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void) -> any TelegramComposerForwardLease
    func submit(request: TelegramSavedMessagesForwardRequest,
                receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramComposerForwardLease
}

/// Separate from the ordinary Saved Messages composer and its pending forward.
@MainActor public final class TelegramSavedMessagesForwardController: ObservableObject {
    @Published public private(set) var phase: TelegramMessageActionPhase = .idle { didSet { didChange?() } }
    @Published public private(set) var error: String?
    public var isBusy: Bool { phase == .validating || phase == .committing }
    public var requestID: UUID? { request?.id }
    var request: TelegramSavedMessagesForwardRequest?
    var didQueue: ((TelegramSavedMessagesForwardRequest) -> Void)?
    var didChange: (() -> Void)?
    private var provider: (any TelegramSavedMessagesForwardProvider)?
    private var token: UUID?
    private var lease: (any TelegramComposerForwardLease)?
    private var deadline: Task<Void, Never>?
    public init() {}
    func bind(_ provider: (any TelegramSavedMessagesForwardProvider)?) {
        reset(); self.provider = provider
        guard let provider else { return }
        let token = UUID(), accountID = provider.accountID; self.token = token; phase = .validating; armDeadline(token)
        let returned = provider.recover { [weak self] result in
            guard let self, self.token == token else { return }
            switch result {
            case .failure: self.complete(.uncertain); self.error = "Не удалось прочитать результат пересылки в Избранное. Данные не изменены."
            case .success(nil): self.complete(.idle)
            case let .success(record?):
                guard record.isValid, record.request.accountID == accountID else { self.complete(.uncertain); return }
                self.request = record.request
                self.complete(record.acceptedIDs == nil ? .uncertain : .queued)
            }
        }
        install(returned, token: token)
    }
    @discardableResult func perform(_ request: TelegramSavedMessagesForwardRequest) -> Bool {
        guard !isBusy, phase != .uncertain, phase != .queued || self.request?.id != request.id,
              request.isValid, let provider, provider.accountID == request.accountID else { return false }
        reset(); self.provider = provider; self.request = request
        let token = UUID(); self.token = token; phase = .validating; armDeadline(token)
        let returned = provider.submit(request: request) { [weak self] event in
            guard let self, self.token == token, self.isBusy else { return }
            switch event {
            case .committing: self.phase = .committing
            case .queued: self.complete(.queued); self.didQueue?(request)
            case .rejected: self.complete(.rejected)
            case .uncertain, .applied: self.complete(.uncertain)
            }
        }
        install(returned, token: token)
        return true
    }
    public func cancel() { guard isBusy else { return }; complete(.uncertain) }
    func timeout() { cancel() }
    private func armDeadline(_ token: UUID) {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.token == token else { return }; self?.timeout()
        }
    }
    private func install(_ returned: any TelegramComposerForwardLease, token: UUID) {
        if self.token == token && isBusy { lease = returned } else { returned.cancel() }
    }
    private func complete(_ phase: TelegramMessageActionPhase) {
        token = nil; deadline?.cancel(); deadline = nil; self.phase = phase
        let old = lease; lease = nil; old?.cancel()
    }
    private func reset() { complete(.idle); error = nil; request = nil; provider = nil }
    isolated deinit { deadline?.cancel(); lease?.cancel() }
}
