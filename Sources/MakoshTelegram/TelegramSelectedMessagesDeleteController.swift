import Foundation
import Combine

public struct TelegramSelectedMessagesDeleteRequest: Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let revision: UUID
    public let contextID: UUID
    public let accountID: Int64
    public let chatID: Int64
    public let sources: [TelegramMessageActionSource]
    public let forEveryone: Bool
    init(session: TelegramMessageSelectionSession, forEveryone: Bool) {
        id = UUID(); sessionID = session.id; revision = session.revision; contextID = session.contextID
        accountID = session.accountID; chatID = session.chatID; sources = session.sources; self.forEveryone = forEveryone
    }
}

func telegramSelectedMessagesDeleteAllowed(_ request: TelegramSelectedMessagesDeleteRequest) -> Bool {
    guard (1...100).contains(request.sources.count),
          !request.forEveryone || request.chatID != request.accountID else { return false }
    var ids = Set<TelegramMessageSelectionID>()
    return request.sources.allSatisfy { source in
        source.accountID == request.accountID && source.chatID == request.chatID &&
        TelegramComposerForwardSource(source: source).isValid &&
        (source.peerID == request.chatID || source.metadata.migrationChatID == request.chatID) &&
        ids.insert(.init(source: source)).inserted &&
        (request.forEveryone ? source.canDeleteForEveryone : source.canDeleteLocally)
    }
}

@MainActor public final class TelegramSelectedMessagesDeleteController: ObservableObject {
    @Published public private(set) var phase: TelegramMessageActionPhase = .idle
    @Published public private(set) var request: TelegramSelectedMessagesDeleteRequest?
    public var isBusy: Bool { phase == .validating || phase == .committing }
    var didQueue: ((TelegramSelectedMessagesDeleteRequest) -> Void)?
    private var provider: (any TelegramSelectedMessagesDeleteProvider)?
    private var lease: (any TelegramMessageActionsLease)?
    private var token: UUID?
    private var deadline: Task<Void, Never>?
    public init() {}
    func bind(provider: (any TelegramSelectedMessagesDeleteProvider)?) { reset(); self.provider = provider }
    @discardableResult func perform(request: TelegramSelectedMessagesDeleteRequest) -> Bool {
        guard !isBusy, phase != .uncertain else { return false }
        self.request = request
        guard let provider, provider.accountID == request.accountID,
              telegramSelectedMessagesDeleteAllowed(request) else { phase = .rejected; return false }
        let id = UUID(); token = id; phase = .validating
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.token == id else { return }; self?.timeout()
        }
        let result = provider.start(request: request) { [weak self] event in
            guard let self, self.token == id, self.isBusy else { return }
            switch event {
            case .committing: self.phase = .committing
            case .queued:
                self.complete(.queued); self.didQueue?(request)
            case .rejected: self.complete(.rejected)
            case .uncertain, .applied: self.complete(.uncertain)
            }
        }
        if token == id && isBusy { lease = result } else { result.cancel() }
        return true
    }
    public func cancel() {
        guard isBusy else { return }
        // Only an explicit provider refusal proves no mutation after dispatch.
        complete(.uncertain)
    }
    func timeout() { cancel() }
    private func complete(_ next: TelegramMessageActionPhase) {
        token = nil; deadline?.cancel(); deadline = nil; phase = next
        let old = lease; lease = nil; old?.cancel()
    }
    public func reset() { complete(.idle); request = nil; provider = nil }
    isolated deinit { deadline?.cancel(); lease?.cancel() }
}
