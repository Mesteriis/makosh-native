import Foundation
import Combine
import TelegramCore
import Postbox
import SwiftSignalKit

/// Search owns independent, cancellable requests. Binding is explicit and never
/// opens an account; local search does not initiate remote peer discovery.
@MainActor
public final class TelegramSearchModel: ObservableObject {
    public let isGlobal: Bool
    @Published public var chatQuery = "" { didSet { if oldValue != chatQuery { searchChats() } } }
    @Published public var messageQuery = "" { didSet { if oldValue != messageQuery { searchMessages(reset: true) } } }
    @Published public var mediaFilter: TelegramSearchMediaFilter = .all { didSet { if oldValue != mediaFilter { searchMessages(reset: true) } } }
    @Published public var scope: TelegramSearchScope = .all { didSet { if oldValue != scope { searchMessages(reset: true) } } }
    @Published public var senderID: Int64? { didSet { if oldValue != senderID { searchMessages(reset: true) } } }
    @Published public var scopedChat: TelegramChat? { didSet { if oldValue != scopedChat { searchMessages(reset: true) } } }
    @Published public var showsResults = true
    @Published public private(set) var selectedResultID: String?
    @Published public private(set) var resultContextID = UUID()
    @Published public private(set) var unavailableReason: String?
    @Published public private(set) var dateStatus: TelegramSearchStatus = .idle
    @Published public private(set) var chats: [TelegramChat] = []
    @Published public private(set) var messages: [TelegramMessage] = []
    @Published public private(set) var chatStatus: TelegramSearchStatus = .idle
    @Published public private(set) var messageStatus: TelegramSearchStatus = .idle
    @Published public private(set) var totalMessages = 0
    public var hasChatQuery: Bool { !chatQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var criteria: TelegramSearchCriteria {
        TelegramSearchCriteria(query: messageQuery, senderID: senderID, media: mediaFilter, scope: scope,
            chatID: isGlobal ? scopedChat?.id : chatID, threadID: isGlobal ? nil : threadID)
    }
    public var hasMessageQuery: Bool { (isGlobal || chatID != nil) && criteria.isActive }
    public var selectedResultIndex: Int? { selectedResultID.flatMap { id in messages.firstIndex { $0.id == id } } }
    public var canSelectNewer: Bool { selectedResultIndex.map { $0 > 0 } ?? false }
    public var canSelectOlder: Bool {
        return selectedResultIndex.map { $0 + 1 < messages.count || canLoadMoreMessages } ?? !messages.isEmpty
    }
    public let senders = TelegramSearchSenders()
    public var canLoadMoreMessages: Bool { messageTracker.canLoadMore }
    public var canRetryMessages: Bool { messageTracker.canRetry }
    var chatRequestID: UUID? { chatTracker.requestID }
    var messageRequestID: UUID? { messageTracker.requestID }

    enum MessageCursor {
        case server(SearchMessagesState)
        #if DEBUG
        case synthetic(Int)
        #endif
    }
    private var account: Account?
    private var chatID: Int64?
    private var threadID: Int64?
    private var folder: TelegramChatFolder = .inbox
    private var chatTracker = TelegramSearchTracker<Void>()
    private var messageTracker = TelegramSearchTracker<MessageCursor>()
    private var indexes: [String: MessageIndex] = [:]
    private var destinations: [String: TelegramChat] = [:]
    private var destinationThreads: [String: Int64] = [:]
    private var suppressRequests = false
    private var pendingOlderIndex: Int?
    var selectionDidChange: ((String, UUID) -> Void)?
    var dateDidSelect: ((MessageIndex, String, UUID) -> Void)?
    private let dateRequest = MetaDisposable()
    private var dateRequestID: UUID?
    private var dateDeadline: Task<Void, Never>?
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

    public init(global: Bool = false) { isGlobal = global }

    isolated deinit {
        chatTask?.cancel(); messageTask?.cancel()
        chatDeadline?.cancel(); messageDeadline?.cancel()
        chatRequest.dispose(); messageRequest.dispose()
        dateRequest.dispose(); dateDeadline?.cancel()
    }

    func bind(account: Account?) {
        cancelChats(); cancelMessages()
        self.account = account
        chatID = nil; threadID = nil
        senders.bind(account: account, chatID: nil, threadID: nil)
        #if DEBUG
        preview = nil
        failNextPreviewMessageRequest = false
        #endif
        chatQuery = ""; clearMessageSearch()
    }

    func selectChat(_ id: Int64?, threadID: Int64? = nil) {
        guard chatID != id || self.threadID != threadID else { return }
        chatID = id; self.threadID = threadID
        clearMessageSearch()
        senders.bind(account: account, chatID: id, threadID: threadID)
        #if DEBUG
        if let preview { senders.useSyntheticPreview(isGroup: preview.forum && id == 10001) }
        #endif
    }

    func setFolder(_ folder: TelegramChatFolder) {
        guard self.folder != folder else { return }
        self.folder = folder
        searchChats()
    }

    func messageIndex(id: String, inChat selectedChatID: Int64?, threadID: Int64? = nil) -> MessageIndex? {
        guard chatID == selectedChatID, self.threadID == threadID else { return nil }
        return indexes[id]
    }

    func resultDestination(id: String, contextID: UUID) -> (TelegramChat, MessageIndex, Int64?)? {
        guard resultContextID == contextID, let index = indexes[id],
              messages.contains(where: { $0.id == id }), let chat = destinations[id] else { return nil }
        // A peer search may include the migrated group's older indexes. Keep
        // its modern selected conversation while retaining the exact old index.
        return (isGlobal ? scopedChat ?? chat : chat, index, destinationThreads[id])
    }

    public func resultChatTitle(id: String) -> String? { destinations[id]?.title }

    public func clearMessageSearch() {
        suppressRequests = true
        messageQuery = ""; senderID = nil; mediaFilter = .all; scope = .all; scopedChat = nil
        suppressRequests = false
        cancelMessages()
    }

    public func selectResult(id: String, contextID: UUID) {
        guard contextID == resultContextID, indexes[id] != nil, messages.contains(where: { $0.id == id }) else { return }
        cancelDate()
        pendingOlderIndex = nil
        selectedResultID = id; showsResults = false
        selectionDidChange?(id, contextID)
    }

    public func selectOlderResult() {
        guard canSelectOlder else { return }
        let next = selectedResultIndex.map { $0 + 1 } ?? 0
        if next < messages.count { selectResult(id: messages[next].id, contextID: resultContextID) }
        else { pendingOlderIndex = next; loadMoreMessages() }
    }

    public func selectNewerResult() {
        guard let index = selectedResultIndex, index > 0 else { return }
        selectResult(id: messages[index - 1].id, contextID: resultContextID)
    }

    public func jumpToDate(_ date: Date, calendar: Calendar = .current) {
        cancelDate()
        guard !isGlobal, let chatID,
              let timestamp = telegramSearchDayTimestamp(date, calendar: calendar) else { dateStatus = .failed; return }
        let context = resultContextID, token = beginDateRequest(), thread = threadID
        #if DEBUG
        if let preview {
            let matches = preview.searchMessages(chatID: chatID, query: "", threadID: thread)
            guard let closest = matches.items.min(by: { abs($0.date.timeIntervalSince1970 - Double(timestamp)) < abs($1.date.timeIntervalSince1970 - Double(timestamp)) }),
                  let index = matches.indexes[closest.id] else { dateStatus = .failed; return }
            receiveDate(index: index, id: closest.id, token: token, context: context)
            return
        }
        #endif
        guard let account else { dateStatus = .failed; return }
        dateDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.dateRequestID == token else { return }
            self.dateRequestID = nil; self.dateRequest.set(nil); self.dateStatus = .timedOut
        }
        let engine = TelegramEngine(account: account)
        dateRequest.set((engine.messages.searchMessageIdByTimestamp(peerId: PeerId(chatID), threadId: thread, timestamp: timestamp)
            |> take(1) |> mapToSignal { id -> Signal<Message?, NoError> in
                guard let id else { return .single(nil) }
                return engine.messages.downloadMessage(messageId: id) |> take(1)
            } |> deliverOnMainQueue).start(next: { [weak self] message in
                guard let self, self.dateRequestID == token, self.resultContextID == context else { return }
                guard let message, thread == nil || message.threadId == thread else {
                    self.dateDeadline?.cancel(); self.dateDeadline = nil; self.dateStatus = .failed; return
                }
                self.receiveDate(index: message.index, id: TelegramMessage(message).id, token: token, context: context)
            }))
    }

    /// Native timestamp lookup and message download share one cancellable token.
    func beginDateRequest() -> UUID {
        cancelDate()
        pendingOlderIndex = nil
        let token = UUID()
        dateRequestID = token; dateStatus = .loading
        return token
    }

    private func cancelDate() {
        dateRequest.set(nil); dateDeadline?.cancel(); dateDeadline = nil
        dateRequestID = nil; dateStatus = .idle
    }

    func receiveDate(index: MessageIndex, id: String, token: UUID, context: UUID) {
        guard dateRequestID == token, resultContextID == context else { return }
        dateDeadline?.cancel(); dateDeadline = nil; dateRequestID = nil; dateStatus = .ready
        showsResults = false; selectedResultID = nil
        dateDidSelect?(index, id, context)
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
        destinations = [:]; destinationThreads = [:]; selectedResultID = nil; pendingOlderIndex = nil
        resultContextID = UUID(); showsResults = true
        unavailableReason = nil
        cancelDate()
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
                    account.postbox.transaction { transaction -> [TelegramSearchChatPresenceSource] in
                        peers.compactMap { rendered in
                            guard let peer = rendered.peer,
                                  transaction.getPeerChatListIndex(peer.id)?.0 == group else { return nil }
                            let preview = transaction.getTopPeerMessageIndex(peerId: peer.id).flatMap { transaction.getMessage($0.id) }?.text ?? ""
                            let unread = transaction.getCombinedPeerReadState(peer.id)?.count ?? 0
                            let presencePeerID = peer.associatedPeerOverridesIdentity ? (peer.associatedPeerId ?? peer.id) : peer.id
                            return TelegramSearchChatPresenceSource(
                                chat: TelegramChat(id: peer.id.toInt64(), title: telegramPeerTitle(peer), preview: preview, unreadCount: Int(unread)),
                                presencePeerID: presencePeerID)
                        }
                    }
                }
                |> mapToSignal { sources in
                    telegramSearchChatPresenceSignal(postbox: account.postbox, sources: sources,
                        accountID: account.peerId.toInt64(), serverTimeOffset: { account.network.globalTimeDifference })
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
        guard !suppressRequests else { return }
        if reset { cancelMessages() }
        else {
            messageTask?.cancel(); messageTask = nil
            messageDeadline?.cancel(); messageDeadline = nil
            messageRequest.set(nil)
        }
        let criteria = self.criteria
        guard hasMessageQuery, let location = criteria.nativeLocation else { return }
        // The pinned secret peer search ignores fromId. Never present unfiltered
        // results as a successful sender-filtered search.
        if let id = criteria.chatID, PeerId(id).namespace == Namespaces.Peer.SecretChat,
           criteria.senderID != nil || (criteria.query.isEmpty && criteria.media != .all) {
            unavailableReason = "Этот фильтр пока недоступен для секретного чата. Введите текст для поиска вложений."
            messageStatus = .failed; return
        }
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
                let matches = preview.searchMessages(criteria: criteria)
                let end = min(offset + 50, matches.items.count)
                let failed = self.failNextPreviewMessageRequest
                self.failNextPreviewMessageRequest = false
                let threads = Dictionary(matches.items.compactMap { item -> (String, Int64)? in
                    guard preview.forum, matches.destinations[item.id]?.id == 10001,
                          let thread = item.actionMetadata?.threadID else { return nil }
                    return (item.id, thread)
                }, uniquingKeysWith: { first, _ in first })
                self.receiveMessages(Array(matches.items.prefix(end)), indexes: matches.indexes,
                    destinations: matches.destinations, threads: threads,
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
            self.messageRequest.set((TelegramEngine(account: account).messages.searchMessages(
                location: location, query: criteria.query, state: state, centerId: nil, limit: 50)
                |> deliverOnMainQueue).start(next: { [weak self] result, state in
                    guard let self, self.messageTracker.requestID == token else { return }
                    if !result.searchFailed {
                        self.mediaSources = Dictionary(result.messages.flatMap(telegramAttachments).map { ($0.attachment.id, $0) }, uniquingKeysWith: { _, last in last })
                    }
                    let items = result.messages.map { TelegramMessage($0, accountID: account.peerId.toInt64()) }
                    let indexes = Dictionary(zip(items, result.messages).map { ($0.id, $1.index) }, uniquingKeysWith: { first, _ in first })
                    let destinations = Dictionary(zip(items, result.messages).compactMap { item, message -> (String, TelegramChat)? in
                        guard let peer = message.peers[message.id.peerId] else { return nil }
                        return (item.id, TelegramChat(id: peer.id.toInt64(), title: telegramPeerTitle(peer), preview: "", unreadCount: 0))
                    }, uniquingKeysWith: { first, _ in first })
                    let threads = Dictionary(zip(items, result.messages).compactMap { item, message -> (String, Int64)? in
                        guard let thread = telegramSearchNavigationThread(peer: message.peers[message.id.peerId], threadID: message.threadId) else { return nil }
                        return (item.id, thread)
                    }, uniquingKeysWith: { first, _ in first })
                    self.receiveMessages(items, indexes: indexes, destinations: destinations, threads: threads, cursor: .server(state), total: Int(result.totalCount),
                        completed: result.completed, failed: result.searchFailed, requestID: token)
                }))
        }
    }

    func receiveMessages(_ messages: [TelegramMessage], indexes: [String: MessageIndex],
                                 destinations: [String: TelegramChat], threads: [String: Int64],
                                 cursor: MessageCursor, total: Int, completed: Bool, failed: Bool, requestID: UUID) {
        guard messageTracker.receive(requestID: requestID, state: cursor, completed: completed, failed: failed) else { return }
        messageDeadline?.cancel(); messageDeadline = nil
        if !failed {
            self.messages = messages; self.indexes = indexes; self.destinations = destinations
            destinationThreads = threads; totalMessages = total
        }
        messageStatus = messageTracker.status
        mediaSourcesDidChange?()
        if !failed, let next = pendingOlderIndex {
            pendingOlderIndex = nil
            if next < messages.count { selectResult(id: messages[next].id, contextID: resultContextID) }
        }
    }

    #if DEBUG
    func useSyntheticPreview(presenceObservedAt: Date? = nil, albums: Bool = false, forum: Bool = false) {
        bind(account: nil)
        preview = TelegramSyntheticPages(presenceObservedAt: presenceObservedAt, albums: albums, forum: forum)
    }

    public func failNextSyntheticMessageSearch() {
        guard preview != nil else { return }
        failNextPreviewMessageRequest = true
    }
    #endif
}
