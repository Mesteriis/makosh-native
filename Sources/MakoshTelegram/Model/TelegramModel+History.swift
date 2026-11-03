import Foundation
import Combine
import TelegramCore
import Postbox
import SwiftSignalKit

/// Chat list and history paging, focus and notification activation.
extension TelegramModel {
    public var historyItems: [TelegramHistoryItem] {
        guard let accountID = draftAccountID, let chatID = selectedChatID else { return [] }
        return TelegramHistoryItem.project(messages, accountID: accountID, chatID: chatID)
    }

    public var historyWindowID: UUID? { historyPages.requestID }

    public var historyReadContext: TelegramHistoryReadContext? {
        guard phase == .ready, !search.hasMessageQuery, !historyPage.isLoading, !historyPage.timedOut,
            let accountID = draftAccountID, let chatID = selectedChatID,
            let windowID = historyWindowID
        else { return nil }
        return TelegramHistoryReadContext(
            accountID: accountID, chatID: chatID,
            accountContextID: accountGeneration, historyWindowID: windowID, threadID: selectedThreadID)
    }

    public var readyHistoryFocusID: String? {
        guard !historyPage.isLoading, !historyPage.timedOut,
            let id = historyFocusID, messages.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    var chatWindowID: UUID? { chatPages.requestID }

    public func loadOlderChats() {
        guard chatPages.canLoadPrevious, let cursor = chatPages.previousCursor else { return }
        loadChatList(anchor: cursor)
    }

    public func loadNewerChats() {
        guard chatPages.canLoadNext, let cursor = chatPages.nextCursor else { return }
        loadChatList(anchor: cursor)
    }

    public func showLatestChats() { loadChatList() }

    public func retryChatPage() { loadChatList(anchor: chatPages.anchor) }

    public func loadOlderMessages() {
        guard historyPages.canLoadPrevious, let cursor = historyPages.previousCursor else { return }
        loadHistory(anchor: cursor, clear: false)
    }

    public func loadNewerMessages() {
        guard historyPages.canLoadNext, let cursor = historyPages.nextCursor else { return }
        loadHistory(anchor: cursor, clear: false)
    }

    public func showLatestMessages() { loadHistory(clear: false) }

    public func retryHistoryPage() { loadHistory(anchor: historyPages.anchor, clear: false) }

    public func openSearchMessage(id: String, contextID: UUID? = nil) {
        // Migrated-group matches have the old peer ID. Postbox includes that
        // associated history; validate the search's selected chat, not the index peer.
        guard search.messageIndex(id: id, inChat: selectedChatID, threadID: selectedThreadID) != nil else { return }
        search.selectResult(id: id, contextID: contextID ?? search.resultContextID)
    }

    public func openGlobalSearchMessage(id: String, contextID: UUID) {
        globalSearch.selectResult(id: id, contextID: contextID)
    }

    func activateGlobalSearchResult(id: String, contextID: UUID) {
        guard phase == .ready, !isBusy, !messageActions.isBusy, upload.phase == .idle,
            !isComposerSuspended, !isForwardComposerLocked, !selectedMessagesDeletionBlocksActions,
            let (chat, index, thread) = globalSearch.resultDestination(id: id, contextID: contextID),
            thread.map({ $0 > 0 && $0 <= Int64(Int32.max) }) ?? true
        else { return }
        knownChats[chat.id] = chat
        selectedChatID = chat.id
        if thread != selectedThreadID { selectThread(thread) }
        isForumTopicsListPresented = false
        loadHistory(anchor: index, clear: false, focusID: id)
    }

    public func clearHistoryFocus() { historyFocusID = nil }

    func activateNotification(_ event: TelegramNotificationEvent) -> Bool {
        guard phase == .ready, !isBusy, !messageActions.isBusy, upload.phase == .idle,
            !isComposerSuspended, !isForwardComposerLocked, !selectedMessagesDeletionBlocksActions,
            notifications.accountID == event.accountID,
            account?.peerId.toInt64() == event.accountID || (isSyntheticPreview && event.accountID == -1)
        else { return false }
        if knownChats[event.peerID] == nil {
            knownChats[event.peerID] = .init(id: event.peerID, title: event.title, preview: "", unreadCount: 0)
        }
        selectedChatID = event.peerID
        if selectedThreadID != event.threadID { selectThread(event.threadID) }
        isForumTopicsListPresented = false
        if isSyntheticPreview {
            loadHistory()
            return true
        }
        let id = MessageId(peerId: PeerId(event.peerID), namespace: event.namespace, id: event.messageID)
        loadHistory(
            anchor: MessageIndex(id: id, timestamp: event.timestamp), clear: false,
            focusID: "\(event.peerID):\(event.namespace):\(event.messageID)")
        return true
    }

    func loadChatList(anchor: ChatListIndex? = nil, clear: Bool = false) {
        chatList.set(nil)
        chatPageTimeout?.cancel()
        chatPageTimeout = nil
        if clear { chats = [] }
        #if DEBUG
        if let preview {
            let requestID = chatPages.begin(anchor: anchor)
            let page = preview.chats(folder: chatFolder, anchor: anchor, workspaceFolderID: workspaceFolderID)
            receiveChats(page.items, requestID: requestID, previous: page.previous, next: page.next, isLoading: false)
            return
        }
        #endif
        guard let account else {
            chatPages.reset()
            chatPage = .idle
            return
        }
        let token = generation
        let accountToken = accountGeneration
        let folder = chatFolder
        let workspaceID = workspaceFolderID
        let selectedFilter = folder == .inbox ? workspaceNativeFolders.first { $0.id == workspaceID } : nil
        let requestID = chatPages.begin(anchor: anchor)
        chatPage = chatPages.navigation
        updateChatDeadline(requestID: requestID)
        let group: PeerGroupId = folder == .inbox ? .root : Namespaces.PeerGroup.archive
        chatList.set(
            (telegramWorkspaceChatPage(account: account, group: group, filter: selectedFilter, anchor: anchor) |> deliverOnMainQueue).start(
                next: { [weak self] page in
                    guard let self, self.generation == token, self.accountGeneration == accountToken,
                        self.chatFolder == folder, self.workspaceFolderID == workspaceID, self.chatPages.requestID == requestID
                    else { return }
                    self.receiveChats(
                        page.chats, requestID: requestID, previous: page.previous,
                        next: page.next, isLoading: page.isLoading)
                }))
    }

    func loadHistory(anchor: MessageIndex? = nil, clear: Bool = true, focusID: String? = nil) {
        cancelAutomaticDownloads()
        cancelMessageSelectionRange()
        playback.stop()
        historyReadIndexes = [:]
        historyFocusID = focusID
        history.set(nil)
        historyPageTimeout?.cancel()
        historyPageTimeout = nil
        if clear {
            messages = []
            historyMediaSources = []
            refreshMediaSources()
        }
        #if DEBUG
        if let preview, let selectedChatID, knownChats[selectedChatID] != nil {
            let requestID = historyPages.begin(anchor: anchor)
            let page = preview.messages(chatID: selectedChatID, anchor: anchor, threadID: selectedThreadID)
            prepareSyntheticHistoryReadIndexes(page.items)
            receiveMessages(page.items, requestID: requestID, previous: page.previous, next: page.next, isLoading: false)
            return
        }
        #endif
        guard let account, let selectedChatID, knownChats[selectedChatID] != nil else {
            historyPages.reset()
            historyPage = .idle
            return
        }
        let token = generation
        let accountToken = accountGeneration
        let chat = selectedChatID, threadID = selectedThreadID
        let requestID = historyPages.begin(anchor: anchor)
        historyPage = historyPages.navigation
        updateHistoryDeadline(requestID: requestID)
        let index: MessageHistoryAnchorIndex = anchor.map { .message($0) } ?? .upperBound
        history.set(
            (telegramProjectHistoryPage(account: account, chatID: chat, threadID: threadID, index: index)
                |> deliverOnMainQueue).start(next: { [weak self] page in
                    guard let self, self.generation == token, self.accountGeneration == accountToken,
                        self.selectedChatID == chat, self.selectedThreadID == threadID, self.historyPages.requestID == requestID
                    else { return }
                    if !page.messages.isEmpty || !page.isLoading {
                        self.historyMediaSources = page.sources
                        self.historyReadIndexes = page.readIndexes
                    }
                    self.receiveMessages(
                        page.messages, requestID: requestID, previous: page.previous,
                        next: page.next, isLoading: page.isLoading, hasPreviousGap: page.holeEarlier, hasNextGap: page.holeLater)
                }))
    }

    func receiveChats(
        _ items: [TelegramChat], requestID: UUID, previous: ChatListIndex?,
        next: ChatListIndex?, isLoading: Bool
    ) {
        guard
            chatPages.update(
                requestID: requestID, previous: previous, next: next,
                isLoading: isLoading, hasPreviousGap: isLoading)
        else { return }
        chatPage = chatPages.navigation
        updateChatDeadline(requestID: requestID)
        for chat in items { knownChats[chat.id] = chat }
        // Keep the previous window while an empty loading snapshot fills holes.
        // A stable empty snapshot still clears deleted/empty contents.
        if !items.isEmpty || !isLoading { chats = items }
    }

    func receiveMessages(
        _ items: [TelegramMessage], requestID: UUID, previous: MessageIndex?,
        next: MessageIndex?, isLoading: Bool, hasPreviousGap: Bool = false,
        hasNextGap: Bool = false
    ) {
        guard
            historyPages.update(
                requestID: requestID, previous: previous, next: next,
                isLoading: isLoading, hasPreviousGap: hasPreviousGap, hasNextGap: hasNextGap)
        else { return }
        historyPage = historyPages.navigation
        updateHistoryDeadline(requestID: requestID)
        if !items.isEmpty || !isLoading {
            messages = items
            refreshCustomEmojiDescriptors()
        }
        if let chatID = selectedChatID {
            messageSelection.observe(sources: items.compactMap(actionSource), contextID: conversationGeneration, chatID: chatID)
        }
        if messageSelection.rangeRequest == nil || historyPage.isLoading { cancelMessageSelectionRange() }
        refreshMediaSources()
    }

    func updateChatDeadline(requestID: UUID) {
        guard chatPage.isLoading else {
            chatPageTimeout?.cancel()
            chatPageTimeout = nil
            return
        }
        guard chatPageTimeout == nil else { return }
        chatPageTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.chatPages.timeout(requestID: requestID) else { return }
            self.chatPageTimeout = nil
            self.chatPage = self.chatPages.navigation
        }
    }

    func updateHistoryDeadline(requestID: UUID) {
        guard historyPage.isLoading else {
            historyPageTimeout?.cancel()
            historyPageTimeout = nil
            return
        }
        guard historyPageTimeout == nil else { return }
        historyPageTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.historyPages.timeout(requestID: requestID) else { return }
            self.historyPageTimeout = nil
            self.historyPage = self.historyPages.navigation
        }
    }
}
