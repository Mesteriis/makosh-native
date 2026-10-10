import Foundation
import Combine
import TelegramCore
import Postbox
import SwiftSignalKit

/// Search owns independent, cancellable requests. Binding is explicit and never
/// opens an account; local search does not initiate remote peer discovery.
@MainActor
public final class TelegramSearchModel: ObservableObject {
    @Published public var chatQuery = "" { didSet { if oldValue != chatQuery { searchChats() } } }
    @Published public var messageQuery = "" { didSet { if oldValue != messageQuery { searchMessages(reset: true) } } }
    @Published public private(set) var chats: [TelegramChat] = []
    @Published public private(set) var messages: [TelegramMessage] = []
    @Published public private(set) var chatStatus: TelegramSearchStatus = .idle
    @Published public private(set) var messageStatus: TelegramSearchStatus = .idle
    @Published public private(set) var totalMessages = 0
    public var hasChatQuery: Bool { !chatQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasMessageQuery: Bool { !messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canLoadMoreMessages: Bool { messageTracker.canLoadMore }
    public var canRetryMessages: Bool { messageTracker.canRetry }
    var chatRequestID: UUID? { chatTracker.requestID }
    var messageRequestID: UUID? { messageTracker.requestID }

    private enum MessageCursor {
        case server(SearchMessagesState)
        #if DEBUG
        case synthetic(Int)
        #endif
    }
    private var account: Account?
    private var chatID: Int64?
    private var folder: TelegramChatFolder = .inbox
    private var chatTracker = TelegramSearchTracker<Void>()
    private var messageTracker = TelegramSearchTracker<MessageCursor>()
    private var indexes: [String: MessageIndex] = [:]
    private(set) var mediaSources: [String: TelegramAttachmentSource] = [:]
    var mediaSourcesDidChange: (() -> Void)?
    private var chatTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var chatDeadline: Task<Void, Never>?
    private var messageDeadline: Task<Void, Never>?
    private let chatRequest = MetaDisposable()
    private let messageRequest = MetaDisposable()
    #if DEBUG
    private var preview: TelegramSyntheticPages?
    private var failNextPreviewMessageRequest = false
    #endif

    public init() {}

    isolated deinit {
        chatTask?.cancel(); messageTask?.cancel()
        chatDeadline?.cancel(); messageDeadline?.cancel()
        chatRequest.dispose(); messageRequest.dispose()
    }

    func bind(account: Account?) {
        cancelChats(); cancelMessages()
        self.account = account
        chatID = nil
        #if DEBUG
        preview = nil
        failNextPreviewMessageRequest = false
        #endif
        chatQuery = ""; messageQuery = ""
    }

    func selectChat(_ id: Int64?) {
        guard chatID != id else { return }
        chatID = id
        cancelMessages()
        messageQuery = ""
    }

    func setFolder(_ folder: TelegramChatFolder) {
        guard self.folder != folder else { return }
        self.folder = folder
        searchChats()
    }

    func messageIndex(id: String, inChat selectedChatID: Int64?) -> MessageIndex? {
        guard chatID == selectedChatID else { return nil }
        return indexes[id]
    }

    public func retryChats() { searchChats() }
    public func retryMessages() {
        guard messageTracker.canRetry else { return }
        searchMessages(reset: false, debounce: false)
    }
    public func loadMoreMessages() {
        guard messageTracker.canLoadMore else { return }
        searchMessages(reset: false, debounce: false)
    }

    private func cancelChats() {
        chatTask?.cancel(); chatTask = nil
        chatDeadline?.cancel(); chatDeadline = nil
        chatRequest.set(nil); chatTracker.reset()
        chats = []; chatStatus = .idle
    }

    private func cancelMessages() {
        messageTask?.cancel(); messageTask = nil
        messageDeadline?.cancel(); messageDeadline = nil
        messageRequest.set(nil); messageTracker.reset()
        messages = []; indexes = [:]; totalMessages = 0; messageStatus = .idle
        mediaSources = [:]; mediaSourcesDidChange?()
    }

    private func searchChats() {
        cancelChats()
        let query = chatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let token = chatTracker.begin()
        chatStatus = chatTracker.status
        chatTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.chatTracker.requestID == token else { return }
            #if DEBUG
            if let preview = self.preview {
                self.receiveChats(preview.searchChats(folder: self.folder, query: query), requestID: token)
                return
            }
            #endif
            guard let account = self.account else { self.cancelChats(); return }
            self.chatDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.chatTracker.timeout(requestID: token) else { return }
                self.chatDeadline = nil; self.chatStatus = self.chatTracker.status
            }
            let group: PeerGroupId = self.folder == .inbox ? .root : Namespaces.PeerGroup.archive
            let signal = account.postbox.searchPeers(query: query)
                |> mapToSignal { peers in
                    account.postbox.transaction { transaction -> [TelegramChat] in
                        peers.compactMap { rendered in
                            guard let peer = rendered.peer,
                                  transaction.getPeerChatListIndex(peer.id)?.0 == group else { return nil }
                            let preview = transaction.getTopPeerMessageIndex(peerId: peer.id).flatMap { transaction.getMessage($0.id) }?.text ?? ""
                            let unread = transaction.getCombinedPeerReadState(peer.id)?.count ?? 0
                            return TelegramChat(id: peer.id.toInt64(), title: telegramPeerTitle(peer), preview: preview, unreadCount: Int(unread))
                        }
                    }
                }
            self.chatRequest.set((signal |> deliverOnMainQueue).start(next: { [weak self] chats in
                self?.receiveChats(chats, requestID: token)
            }))
        }
    }

    func receiveChats(_ chats: [TelegramChat], requestID: UUID) {
        guard chatTracker.receive(requestID: requestID, state: (), completed: true, failed: false) else { return }
        chatDeadline?.cancel(); chatDeadline = nil
        self.chats = chats; chatStatus = chatTracker.status
    }

    private func searchMessages(reset: Bool, debounce: Bool = true) {
        if reset { cancelMessages() }
        else {
            messageTask?.cancel(); messageTask = nil
            messageDeadline?.cancel(); messageDeadline = nil
            messageRequest.set(nil)
        }
        let query = messageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let chatID else { return }
        let token = messageTracker.begin()
        messageStatus = messageTracker.status
        messageTask = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard let self, self.messageTracker.requestID == token else { return }
            #if DEBUG
            if let preview = self.preview {
                var offset = 0
                if case let .synthetic(value) = self.messageTracker.state { offset = value }
                let matches = preview.searchMessages(chatID: chatID, query: query)
                let end = min(offset + 50, matches.items.count)
                let failed = self.failNextPreviewMessageRequest
                self.failNextPreviewMessageRequest = false
                self.receiveMessages(Array(matches.items.prefix(end)), indexes: matches.indexes,
                    cursor: .synthetic(end), total: matches.items.count, completed: end == matches.items.count,
                    failed: failed, requestID: token)
                return
            }
            #endif
            guard let account = self.account else { self.cancelMessages(); return }
            self.messageDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.messageTracker.timeout(requestID: token) else { return }
                self.messageDeadline = nil; self.messageStatus = self.messageTracker.status
            }
            var state: SearchMessagesState?
            if case let .server(value) = self.messageTracker.state { state = value }
            let location = SearchMessagesLocation.peer(peerId: PeerId(chatID), fromId: nil, tags: nil,
                reactions: nil, threadId: nil, minDate: nil, maxDate: nil)
            self.messageRequest.set((TelegramEngine(account: account).messages.searchMessages(
                location: location, query: query, state: state, centerId: nil, limit: 50)
                |> deliverOnMainQueue).start(next: { [weak self] result, state in
                    guard let self, self.messageTracker.requestID == token else { return }
                    if !result.searchFailed {
                        self.mediaSources = Dictionary(result.messages.flatMap(telegramAttachments).map { ($0.attachment.id, $0) }, uniquingKeysWith: { _, last in last })
                    }
                    let items = result.messages.map(TelegramMessage.init)
                    let indexes = Dictionary(result.messages.map { (TelegramMessage($0).id, $0.index) }, uniquingKeysWith: { first, _ in first })
                    self.receiveMessages(items, indexes: indexes, cursor: .server(state), total: Int(result.totalCount),
                        completed: result.completed, failed: result.searchFailed, requestID: token)
                }))
        }
    }

    private func receiveMessages(_ messages: [TelegramMessage], indexes: [String: MessageIndex],
                                 cursor: MessageCursor, total: Int, completed: Bool, failed: Bool, requestID: UUID) {
        guard messageTracker.receive(requestID: requestID, state: cursor, completed: completed, failed: failed) else { return }
        messageDeadline?.cancel(); messageDeadline = nil
        if !failed { self.messages = messages; self.indexes = indexes; totalMessages = total }
        messageStatus = messageTracker.status
        mediaSourcesDidChange?()
    }

    #if DEBUG
    func useSyntheticPreview() {
        bind(account: nil)
        preview = TelegramSyntheticPages()
    }

    public func failNextSyntheticMessageSearch() {
        guard preview != nil else { return }
        failNextPreviewMessageRequest = true
    }
    #endif
}
