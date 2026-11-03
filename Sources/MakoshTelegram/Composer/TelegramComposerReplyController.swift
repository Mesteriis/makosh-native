import Foundation
import Combine
import SwiftSignalKit

/// Display data resolved from the selected account's current message cache.
/// It is deliberately not part of the durable draft or an authority to send.
public struct TelegramComposerReply: Equatable, Sendable {
    public let source: TelegramMessageActionSource
    public let author: String
    public init(source: TelegramMessageActionSource, author: String) {
        self.source = source; self.author = author
    }
}

public enum TelegramComposerReplyState: Equatable, Sendable {
    case none, loading, unavailable, ready(TelegramComposerReply)
}

@MainActor protocol TelegramComposerReplyProvider: AnyObject {
    var accountID: Int64 { get }
    func resolve(target: TelegramComposerReplyTarget, chatID: Int64,
                 completion: @escaping @MainActor (TelegramComposerReply?) -> Void) -> Disposable
}

/// Owns only the current selection's cancellable lookup. Text and the typed
/// target are owned together by TelegramDraftStore, independently of this view.
@MainActor public final class TelegramComposerReplyController: ObservableObject {
    @Published public private(set) var state: TelegramComposerReplyState = .none
    public var resolved: TelegramComposerReply? {
        if case let .ready(value) = state { return value }; return nil
    }
    public var preventsSend: Bool {
        switch state { case .loading, .unavailable: true; case .none, .ready: false }
    }
    private var provider: (any TelegramComposerReplyProvider)?
    private var target: TelegramComposerReplyTarget?
    private var chatID: Int64?
    private var contextID = UUID()
    private let subscription = MetaDisposable()
    private var deadline: Task<Void, Never>?
    private(set) var requestID: UUID?
    public init() {}
    isolated deinit { cancel() }

    func bind(_ provider: (any TelegramComposerReplyProvider)?) {
        cancel(); contextID = UUID()
        self.provider = provider
        // Never resolve an old account's selection in the newly bound account.
        target = nil; chatID = nil; state = .none
    }

    func select(target: TelegramComposerReplyTarget?, chatID: Int64?, initial: TelegramComposerReply? = nil) {
        guard target != self.target || chatID != self.chatID || initial != nil else { return }
        cancel()
        self.target = target; self.chatID = chatID
        guard let target, let chatID else { state = .none; return }
        if let initial, matches(initial, target: target, chatID: chatID) {
            state = .ready(initial)
        } else { load() }
    }

    public func retry() { load() }

    private func matches(_ value: TelegramComposerReply, target: TelegramComposerReplyTarget, chatID: Int64) -> Bool {
        let source = value.source
        return target.isValid && source.accountID == provider?.accountID && source.chatID == chatID &&
            TelegramComposerReplyTarget(source: source) == target && source.canReply && !source.fingerprint.isEmpty &&
            (source.peerID == chatID || source.metadata.migrationChatID == chatID)
    }

    private func load() {
        cancel()
        guard let target, let chatID else { state = .none; return }
        guard target.isValid, let provider else { state = .unavailable; return }
        let request = UUID(), context = contextID, accountID = provider.accountID
        requestID = request; state = .loading
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.timeout(requestID: request)
        }
        let disposable = provider.resolve(target: target, chatID: chatID) { [weak self] value in
            guard let self, self.requestID == request, self.contextID == context,
                  self.provider?.accountID == accountID, self.target == target, self.chatID == chatID else { return }
            self.cancel()
            if let value, self.matches(value, target: target, chatID: chatID) { self.state = .ready(value) }
            else { self.state = .unavailable }
        }
        // A fixture/cache provider may complete synchronously.
        if requestID == request { subscription.set(disposable) } else { disposable.dispose() }
    }

    func timeout(requestID: UUID) {
        guard self.requestID == requestID else { return }
        cancel(); state = .unavailable
    }

    private func cancel() {
        requestID = nil; deadline?.cancel(); deadline = nil; subscription.set(nil)
    }
}
