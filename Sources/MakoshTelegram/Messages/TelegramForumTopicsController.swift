import Foundation
import Combine
import Postbox
import TelegramCore
import SwiftSignalKit

@MainActor public final class TelegramForumTopicsController: ObservableObject {
    @Published public private(set) var snapshot: TelegramForumTopicsSnapshot?
    @Published public private(set) var phase: TelegramForumTopicsPhase = .idle
    private var provider: ((Int64) -> Signal<Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>, NoError>)?
    private var accountID: Int64?
    private var chatID: Int64?
    private var visible = false
    private var contextID = UUID()
    private var requestID: UUID?
    private let subscription = MetaDisposable()
    private var deadline: Task<Void, Never>?
    private let timeout: Duration

    public init() { timeout = .seconds(30) }
    init(timeout: Duration) { self.timeout = timeout }
    isolated deinit { deadline?.cancel(); subscription.dispose() }

    func bind(account: Account?) {
        bind(accountID: account?.peerId.toInt64(), provider: account.map { account in
            { chatID in telegramForumTopicsSignal(postbox: account.postbox,
                accountID: account.peerId.toInt64(), chatID: chatID) }
        })
    }

    func bind(accountID: Int64?, provider: ((Int64) -> Signal<Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>, NoError>)?) {
        cancel(); contextID = UUID()
        self.accountID = accountID; self.provider = provider; load()
    }

    public func selectChat(_ chatID: Int64?) {
        guard self.chatID != chatID else { return }
        self.chatID = chatID; load()
    }

    public func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible; load()
    }

    private func load() {
        cancel()
        guard visible, let chatID, let accountID, let provider else { return }
        let request = UUID(), context = contextID
        requestID = request; phase = .loading; startDeadline(request: request)
        subscription.set(provider(chatID).start(next: { [weak self] result in
            MainActor.assumeIsolated {
                self?.receive(result, request: request, context: context, accountID: accountID, chatID: chatID)
            }
        }))
    }

    private func receive(_ result: Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>,
        request: UUID, context: UUID, accountID: Int64, chatID: Int64) {
        guard visible, requestID == request, contextID == context,
              self.accountID == accountID, self.chatID == chatID else { return }
        switch result {
        case let .failure(error):
            snapshot = nil; phase = .failed(error); deadline?.cancel(); deadline = nil
        case let .success(value):
            var ids: Set<Int64> = []
            guard value.accountID == accountID, value.chatID == chatID,
                  value.topics.allSatisfy({ topic in
                      topic.accountID == accountID && topic.chatID == chatID && topic.threadID > 0 &&
                          topic.threadID <= Int64(Int32.max) && topic.unreadCount >= 0 &&
                          (topic.pinnedIndex.map { $0 >= 0 } ?? true) && ids.insert(topic.threadID).inserted
                  }) else {
                snapshot = nil; phase = .failed(.incompatible); deadline?.cancel(); deadline = nil; return
            }
            snapshot = value; phase = value.isLoading ? .loading : .ready
            if value.isLoading { startDeadline(request: request) }
            else { deadline?.cancel(); deadline = nil }
        }
    }

    private func startDeadline(request: UUID) {
        guard deadline == nil else { return }
        let timeout = self.timeout
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.requestID == request else { return }
            self.cancel(); self.phase = .failed(.unavailable)
        }
    }

    private func cancel() {
        requestID = nil; snapshot = nil; phase = .idle
        deadline?.cancel(); deadline = nil; subscription.set(nil)
    }
}
