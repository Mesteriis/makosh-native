import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Person profile, profile media, group membership and shared media navigation.
extension TelegramModel {
    public func blockedUserChange(_ profile: TelegramContactProfile, contextID: UUID) -> TelegramBlockedUserChange? {
        guard isCurrentContactProfile(profile, contextID: contextID), profile.isPerson || profile.isBot,
            PeerId(profile.peerID).namespace == Namespaces.Peer.CloudUser,
            accountBlockedUsers.snapshot?.accountID == profile.accountID
        else { return nil }
        return accountBlockedUsers.change(
            userID: PeerId(profile.peerID).id._internalGetInt64Value(), title: String(profile.displayName.prefix(512)))
    }

    /// Explicit opening observes only the selected account's peer view and asks
    /// the native tracker to refresh it. Observation time is not a server ACK.
    public func loadContactProfile() {
        cancelContactProfile()
        guard phase == .ready, let chat = selectedChat, let accountID = draftAccountID else { return }
        let requestID = UUID(), contextID = conversationGeneration
        contactProfileRequestID = requestID
        contactProfileState = .loading
        #if DEBUG
        if isSyntheticPreview {
            let profile =
                peerProfilesPreview
                ? telegramSyntheticPeerProfile(chat: chat, accountID: accountID)
                : TelegramContactProfile(
                    accountID: accountID, peerID: chat.id,
                    displayName: chat.title, username: "synthetic_\(chat.id)", phone: "10000000000",
                    isBot: false, observedAt: Date())
            if !profile.isPerson && !profile.isBot { peerManagement.bind(TelegramSyntheticPeerManagementProvider(profile: profile)) }
            receiveContactProfile(
                profile, requestID: requestID,
                contextID: contextID, accountID: accountID, chatID: chat.id)
            return
        }
        #endif
        guard let account else {
            cancelContactProfile()
            return
        }
        contactProfileTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.contactProfileRequestID == requestID else { return }
            self.contactProfileSubscription.set(nil)
            self.contactProfileRequestID = nil
            self.contactProfileTimeout = nil
            self.contactProfileState = .unavailable("Карточка пока не загрузилась. Повторите запрос.")
        }
        contactProfileSubscription.set(
            telegramPeerProfileSignal(
                account: account, peerID: chat.id,
                accountID: accountID
            ).start(next: { [weak self] profile in
                MainActor.assumeIsolated {
                    self?.receiveContactProfile(
                        profile, requestID: requestID,
                        contextID: contextID, accountID: accountID, chatID: chat.id)
                }
            }))
    }

    func receiveContactProfile(
        _ profile: TelegramContactProfile?, requestID: UUID,
        contextID: UUID, accountID: Int64, chatID: Int64
    ) {
        guard phase == .ready, requestID == contactProfileRequestID, contextID == conversationGeneration,
            accountID == draftAccountID, chatID == selectedChatID,
            profile == nil || (profile?.accountID == accountID && profile?.peerID == chatID)
        else { return }
        contactProfileTimeout?.cancel()
        contactProfileTimeout = nil
        if let profile, !profile.isPerson, !profile.isBot, peerManagement.peerID != chatID { peerManagement.open(peerID: chatID) }
        if let profile, !profile.isPerson, !profile.isBot, groupMembership.peerID != chatID { groupMembership.open(peerID: chatID) }
        // The same guarded request owns subsequent native peer/cache updates.
        contactProfileState =
            profile.map(TelegramContactProfileState.ready)
            ?? .unavailable("Сведения о диалоге пока недоступны. Секретные чаты в этой карточке ещё не поддерживаются.")
    }

    public func isCurrentContactProfile(_ profile: TelegramContactProfile, contextID: UUID) -> Bool {
        phase == .ready && contextID == conversationGeneration && profile.accountID == draftAccountID
            && profile.peerID == selectedChatID && contactProfileState == .ready(profile)
    }

    public func openProfilePhotos(_ profile: TelegramContactProfile, contextID: UUID) -> Bool {
        guard isCurrentContactProfile(profile, contextID: contextID) else { return false }
        profilePhotos.open(peerID: profile.peerID)
        return true
    }

    public func avatarTarget(_ profile: TelegramContactProfile, contextID: UUID) -> TelegramAvatarTarget? {
        guard isCurrentContactProfile(profile, contextID: contextID), avatarEditing.accountID == profile.accountID,
            profile.peerID == profile.accountID || (!profile.isPerson && !profile.isBot)
        else { return nil }
        return .init(accountID: profile.accountID, peerID: profile.peerID, kind: .main)
    }

    public func openGroupMembership(_ profile: TelegramContactProfile, contextID: UUID, section: TelegramGroupMembershipSection) -> Bool {
        guard isCurrentContactProfile(profile, contextID: contextID), !profile.isPerson, !profile.isBot,
            groupMembership.accountID == profile.accountID, groupMembership.peerID == profile.peerID
        else { return false }
        groupMemberSearch.search("")
        return groupMembership.show(section)
    }

    public func inviteGroupMember(
        _ peer: TelegramDiscoveredPeer, searchContextID: UUID,
        basis: TelegramGroupMembershipSnapshot, contextID: UUID
    ) -> Bool {
        guard phase == .ready, draftAccountID == basis.accountID, selectedChatID == basis.peerID,
            case let .ready(profile) = contactProfileState, profile.accountID == basis.accountID, profile.peerID == basis.peerID,
            groupMemberSearch.accountID == basis.accountID, groupMemberSearch.contextID == searchContextID,
            groupMemberSearch.status == .ready, groupMemberSearch.results.contains(peer)
        else { return false }
        return groupMembership.apply(.invite(peer), basis: basis, contextID: contextID)
    }

    public func openSharedMedia(_ profile: TelegramContactProfile, contextID: UUID) -> Bool {
        guard isCurrentContactProfile(profile, contextID: contextID) else { return false }
        sharedMedia.selectChat(profile.peerID)
        sharedMedia.mediaFilter = .photoVideo
        return true
    }

    public func openSharedMediaMessage(id: String, contextID: UUID, profileContextID: UUID) -> Bool {
        guard phase == .ready, profileContextID == contactProfileContextID, !isBusy,
            !messageActions.isBusy, upload.phase == .idle, !isComposerSuspended,
            !isForwardComposerLocked, !selectedMessagesDeletionBlocksActions,
            case let .ready(profile) = contactProfileState,
            isCurrentContactProfile(profile, contextID: profileContextID),
            let (chat, index, thread) = sharedMedia.resultDestination(id: id, contextID: contextID),
            chat.id == selectedChatID
        else { return false }
        cancelContactProfile()
        if selectedThreadID != thread { selectThread(thread) }
        isForumTopicsListPresented = false
        loadHistory(anchor: index, clear: false, focusID: id)
        return true
    }

    public func cancelContactProfile() {
        secretChats.closeCreation()
        profilePhotos.close()
        peerManagement.close()
        groupMembership.close()
        groupMemberSearch.search("")
        sharedMedia.selectChat(nil)
        sharedMedia.clearMessageSearch()
        contactProfileSubscription.set(nil)
        contactProfileTimeout?.cancel()
        contactProfileTimeout = nil
        contactProfileRequestID = nil
        contactProfileState = .idle
    }

    @discardableResult public func openSecretChatCreation(_ profile: TelegramContactProfile, contextID: UUID) -> Bool {
        guard isCurrentContactProfile(profile, contextID: contextID), profile.isPerson, !profile.isBot,
            profile.peerID != profile.accountID, telegramManagementPeerID(profile.peerID)?.namespace == Namespaces.Peer.CloudUser,
            secretChats.accountID == profile.accountID
        else { return false }
        secretChats.openCreation(peerID: profile.peerID)
        return true
    }
}
