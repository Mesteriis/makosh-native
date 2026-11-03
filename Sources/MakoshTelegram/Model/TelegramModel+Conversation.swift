import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Selected conversation capabilities, calls, forum topics and peer discovery.
extension TelegramModel {
    func refreshConversationCapabilities() {
        capabilityObservation.set(nil)
        conversationCapabilities = nil
        secretChats.selectSession(chatID: selectedChatID.flatMap { telegramSecretPeerID($0) == nil ? nil : $0 })
        #if DEBUG
        if secretChatsPreview, let chatID = selectedChatID, let session = secretChats.session {
            conversationCapabilities = .init(
                accountID: syntheticAccountID, chatID: chatID, messageFee: .free,
                secret: .init(
                    regularPeerID: session.regularPeerID, participantTitle: session.title, state: session.state,
                    verification: session.verification))
            return
        }
        if extendedMessagesPreview, isSyntheticPreview, let chatID = selectedChatID {
            let secret: TelegramSecretConversation? =
                chatID == 10002
                ? .init(
                    regularPeerID: 10004,
                    participantTitle: "Синтетический собеседник", state: .active,
                    verification: .init(sha1: Data((0..<20).map(UInt8.init)), sha256: Data((32..<64).map(UInt8.init)))) : nil
            conversationCapabilities = .init(
                accountID: -1, chatID: chatID,
                messageFee: chatID == 10003 ? .stars(3) : .free, secret: secret)
            return
        }
        #endif
        guard let account, let chatID = selectedChatID else { return }
        let context = conversationGeneration, accountID = account.peerId.toInt64()
        capabilityObservation.set(
            telegramConversationCapabilitiesSignal(
                postbox: account.postbox,
                accountID: accountID, chatID: chatID
            ).start(next: { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, self.conversationGeneration == context, self.draftAccountID == accountID,
                        self.selectedChatID == chatID
                    else { return }
                    if case let .success(value) = result {
                        self.conversationCapabilities = value
                    } else {
                        self.conversationCapabilities = nil
                    }
                }
            }))
    }

    public var callPeerID: Int64? {
        guard phase == .ready else { return nil }
        return telegramCallTarget(accountID: draftAccountID, chatID: selectedChatID, secret: conversationCapabilities?.secret)
    }

    func refreshCallSelection() {
        let target = callPeerID
        guard callSelectionAccount != calls.accountID || callSelectionPeer != target else { return }
        callSelectionAccount = calls.accountID
        callSelectionPeer = target
        calls.selectPeer(target)
    }

    public var selectedForumTopic: TelegramForumTopic? {
        forumTopics.snapshot?.topics.first { $0.threadID == selectedThreadID && $0.chatID == selectedChatID }
    }

    @discardableResult public func selectForumTopic(_ topic: TelegramForumTopic, contextID: UUID) -> Bool {
        guard contextID == conversationGeneration, phase == .ready, topic.accountID == draftAccountID,
            topic.chatID == selectedChatID, forumTopics.phase == .ready,
            forumTopics.snapshot?.topics.contains(topic) == true, topic.threadID != selectedThreadID,
            !isBusy, !messageActions.isBusy, upload.phase == .idle, !isComposerSuspended,
            !isForwardComposerLocked, !selectedMessagesDeletionBlocksActions
        else { return false }
        selectThread(topic.threadID)
        return true
    }

    public func showForumAllMessages() {
        guard selectedThreadID != nil, !isBusy, !messageActions.isBusy, upload.phase == .idle,
            !isComposerSuspended, !isForwardComposerLocked, !selectedMessagesDeletionBlocksActions
        else { return }
        selectThread(nil)
    }

    func selectThread(_ threadID: Int64?) {
        cancelVoiceRecording()
        cancelMessageSelectionRange()
        selectedMessagesCopy.cancel()
        messageSelection.cancel()
        cancelContactProfile()
        playback.stop()
        conversationGeneration = UUID()
        selectedThreadID = threadID
        pendingEmojiInsertion = nil
        customEmojiInsertion = nil
        sendApproval.cancel()
        refreshConversationCapabilities()
        if let accountID = draftAccountID, let chatID = selectedChatID {
            displayComposerInput(drafts.snapshot(accountID: accountID, chatID: chatID, threadID: threadID)?.input ?? .empty)
        } else {
            displayComposerInput(.empty)
        }
        projectMessageEditSession()
        refreshComposerReply()
        refreshComposerForward()
        pendingRecoveryAttempt = nil
        cancelPendingRecovery()
        restoreComposerDraft()
        restorePendingUpload()
        refreshServerDraftObservation()
        search.selectChat(selectedChatID, threadID: selectedThreadID)
        loadHistory()
    }

    public var selectedChat: TelegramChat? { selectedChatID.flatMap { knownChats[$0] } }

    @discardableResult public func openDiscoveredPeer(id: Int64, contextID: UUID) -> Bool {
        guard let accountID = draftAccountID, search.discovery.accountID == accountID else { return false }
        return search.discovery.activate(peerID: id, contextID: contextID) { [weak self] chat in
            guard let self, self.draftAccountID == accountID, self.search.discovery.contextID == contextID else { return }
            self.knownChats[chat.id] = chat
            self.selectedChatID = chat.id
        }
    }
}
