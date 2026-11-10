import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

#if DEBUG
/// DEBUG-only synthetic previews used by UI QA and tests.
extension TelegramModel {
    /// Explicit, in-memory UI fixture. Does not open accounts, files or Keychain.
    public static func syntheticPreview(
        albums: Bool = false, forum: Bool = false, twoStepResetWaitSeconds: Int32 = 7 * 86400, dataDefaults: UserDefaults = .standard,
        dataSettings: Bool = false, privacyPremium: Bool = true, calls: TelegramCallController? = nil
    ) -> TelegramModel {
        let model = TelegramModel(
            proxy: TelegramProxyController.synthetic(defaults: dataDefaults), calls: calls, autoDownloadDefaults: dataDefaults)
        model.autoDownloadSettings.bind(accountID: -1)
        let cacheProvider = TelegramSyntheticCacheProvider()
        model.cache.bind(cacheProvider)
        model.cacheMaintenance.bind(provider: cacheProvider)
        let pages = TelegramSyntheticPages(albums: albums, forum: forum, dataSettings: dataSettings)
        model.preview = pages
        model.accountSessions.bind(TelegramSyntheticSessionsProvider())
        model.webSessions.bind(TelegramSyntheticWebSessionsProvider())
        model.appearanceCatalog.bind(TelegramSyntheticAppearanceCatalogProvider())
        model.accountPrivacy.bind(TelegramSyntheticPrivacyProvider(premium: privacyPremium))
        model.accountBlockedUsers.bind(TelegramSyntheticBlockedUsersProvider())
        model.accountTwoStep.bind(TelegramSyntheticTwoStepProvider(resetWaitSeconds: twoStepResetWaitSeconds))
        model.notifications.bind(accountID: -1)
        model.search.useSyntheticPreview(albums: albums, forum: forum)
        model.globalSearch.useSyntheticPreview(albums: albums, forum: forum)
        model.sharedMedia.useSyntheticPreview(albums: albums, forum: forum)
        model.media.bind(provider: TelegramSyntheticMediaProvider())
        model.upload.bind(provider: TelegramSyntheticUploadProvider())
        model.messageActions.bind(provider: TelegramSyntheticMessageActionsProvider())
        model.selectedMessagesCopy.bind(provider: TelegramSyntheticSelectedMessagesCopyProvider(pages: pages))
        model.selectedMessagesDelete.bind(provider: TelegramSyntheticSelectedMessagesDeleteProvider())
        model.savedMessagesForward.bind(TelegramSyntheticSavedMessagesForwardProvider(pages: pages))
        model.composerReply.bind(TelegramSyntheticComposerReplyProvider(pages: pages))
        model.composerForward.bind(TelegramSyntheticForwardProvider(pages: pages))
        model.bindMessageSelectionRangeProvider(TelegramSyntheticSelectionRangeProvider(pages: pages))
        model.bindSyntheticHistoryRead()
        model.isSyntheticPreview = true
        model.archive.configure(repository: TelegramSyntheticArchiveRepository(), synthetic: true)
        model.phase = .ready
        model.connectionDescription = "Синтетическая UI-проверка • сеть и отправка отключены"
        model.contactsProviderValue = TelegramSyntheticContactsProvider(accountID: model.draftAccountID ?? -1)
        model.loadChatList(clear: true)
        return model
    }

    public static func syntheticWorkspaceLayoutPreview() -> TelegramModel {
        let model = syntheticPreview()
        model.avatarEditing.bind(TelegramSyntheticAvatarEditingProvider(profileTitle: "Алексей · профиль QA"))
        model.avatars.bind(TelegramSyntheticAvatarProvider())
        model.preview = TelegramSyntheticPages(workspaceLayout: true)
        model.workspaceFolders = [
            .init(id: 1, title: "Работа"), .init(id: 2, title: "Личные"), .init(id: 3, title: "Проекты"), .init(id: 4, title: "Каналы"),
        ]
        model.selectWorkspaceFolder(1)
        model.selectedChatID = 10001
        return model
    }

    public static func syntheticQRLoginPreview() -> TelegramModel {
        let model = syntheticPreview()
        model.qrLogin.bind(TelegramSyntheticQRLoginProvider())
        model.phase = .phone
        return model
    }
    public static func syntheticExtendedMessagesPreview(specialConversation: String? = nil) -> TelegramModel {
        let model = syntheticPreview(forum: true)
        model.extendedMessagesPreview = true
        do {
            let emoji = try TelegramCustomEmojiSyntheticState.make()
            model.customEmojiPlaybackContext = emoji.playbackContext
            model.customEmojiDescriptors = emoji.descriptors
            model.customEmojiCatalog.bind(provider: emoji.catalogProvider)
            let pages = model.preview
            model.forumTopics.bind(
                accountID: -1,
                provider: { chatID in
                    guard chatID == 10001 else { return .single(.failure(.unavailable)) }
                    return .single(
                        .success(
                            .init(
                                accountID: -1, chatID: chatID,
                                topics: [
                                    .init(accountID: -1, chatID: chatID, threadID: 1, title: "Общие", iconColor: 0x6FB9F0, unreadCount: 3),
                                    .init(
                                        accountID: -1, chatID: chatID, threadID: 7, title: "Разработка", iconFileID: 902,
                                        iconColor: 0x8E70E7,
                                        unreadCount: 2, pinnedIndex: 0,
                                        lastMessage: pages?.messages(chatID: chatID, anchor: nil, threadID: 7).items.last),
                                ], isLoading: false)))
                })
            model.selectedChatID =
                specialConversation == "secret"
                ? 10002 : specialConversation == "paid" ? 10003 : specialConversation == "draft" ? 10004 : 10001
            model.refreshCustomEmojiDescriptors()
            if specialConversation == "draft" {
                let fixture = TelegramServerDraftSyntheticPreview()
                model.bindComposerDraftRepository(fixture)
                model.draft = "Локальный черновик 😀"
                model.bindServerDraftObserver(fixture)
            }
            if specialConversation == "paid" {
                model.sendApproval.bind(provider: TelegramSyntheticSendApprovalProvider(), accountID: 1)
                model.sendApproval.request(
                    context: .init(
                        accountID: 1, chatID: 42, threadID: nil,
                        submissionRevision: UUID(), messageCount: 3), title: "Платный чат · QA"
                ) { [weak model] result in
                    if case .success = result { model?.error = "Синтетическая проверка: платная отправка отключена." }
                }
            }
        } catch { model.error = "Не удалось загрузить синтетические custom emoji." }
        return model
    }

    public static func syntheticPeerProfilesPreview() -> TelegramModel {
        let model = syntheticPreview()
        model.peerProfilesPreview = true
        return model
    }

    var syntheticCalls: TelegramSyntheticCallProvider? {
        get { callsPreviewProvider }
        set { callsPreviewProvider = newValue }
    }
    public func syntheticIncomingCall(video: Bool) { syntheticCalls?.ring(video: video) }
    public static func syntheticCallsPreview() -> TelegramModel {
        let controller = TelegramCallController(permissions: TelegramSyntheticCallPermissions())
        let model = syntheticPreview(calls: controller)
        model.syntheticAccountID = 101
        let provider = TelegramSyntheticCallProvider()
        model.syntheticCalls = provider
        controller.bind(provider)
        model.avatars.bind(TelegramSyntheticAvatarProvider())
        let group = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(91)).toInt64()
        model.chats = [
            .init(id: 42, title: "Synthetic Alice", preview: "Звонки QA", unreadCount: 0),
            .init(id: 43, title: "Synthetic Bob", preview: "Другой собеседник QA", unreadCount: 0),
            .init(id: group, title: "Synthetic group", preview: "Без личных звонков", unreadCount: 0),
        ]
        for chat in model.chats { model.knownChats[chat.id] = chat }
        model.selectedChatID = 42
        model.refreshCallSelection()
        return model
    }

    public static func syntheticAvatarEditingPreview() -> TelegramModel {
        let model = syntheticPeerAppearancePreview()
        model.syntheticAccountID = 101
        model.avatarEditing.bind(TelegramSyntheticAvatarEditingProvider())
        model.accountPrivacy.bind(TelegramSyntheticPrivacyProvider(accountID: 101))
        let group = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(2706)).toInt64()
        let channel = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(5411)).toInt64()
        model.chats = [
            .init(id: 101, title: "Synthetic own profile", preview: "Аватар QA", unreadCount: 0),
            .init(id: group, title: "Synthetic avatar group", preview: "Группа QA", unreadCount: 0),
            .init(id: channel, title: "Synthetic avatar channel", preview: "Канал QA", unreadCount: 0),
        ]
        for chat in model.chats { model.knownChats[chat.id] = chat }
        return model
    }

    public static func syntheticGroupMembershipPreview() -> TelegramModel {
        let model = syntheticAvatarEditingPreview()
        model.groupMembership.bind(TelegramSyntheticGroupMembershipProvider())
        model.groupMemberSearch.bind(TelegramSyntheticRemotePeerProvider(accountID: 101))
        return model
    }
    public static func syntheticSecretChatsPreview() -> TelegramModel {
        let model = syntheticPeerProfilesPreview()
        model.syntheticAccountID = 101
        model.secretChatsPreview = true
        model.secretChats.bind(TelegramSyntheticSecretChatProvider())
        model.preview = TelegramSyntheticPages(secretChats: true)
        model.composerReply.bind(TelegramSyntheticComposerReplyProvider(accountID: 101, pages: model.preview!))
        model.upload.bind(provider: TelegramSyntheticUploadProvider(accountID: 101))
        model.chats =
            [.init(id: 42, title: "Synthetic Alice", preview: "Создание секретного чата", unreadCount: 0)]
            + [44, 45, 46].map { number in
                TelegramChat(
                    id: PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(Int64(number))).toInt64(),
                    title: [44: "Активный секретный чат", 45: "Ожидание секретного чата", 46: "Завершённый секретный чат"][number]!,
                    preview: "Синтетическая проверка", unreadCount: 0)
            }
        for chat in model.chats { model.knownChats[chat.id] = chat }
        model.selectedChatID = 42
        return model
    }

    public static func syntheticPeerAppearancePreview() -> TelegramModel {
        let model = syntheticPeerProfilesPreview()
        let observedAt = Date()
        model.preview = TelegramSyntheticPages(presenceObservedAt: observedAt)
        model.search.useSyntheticPreview(presenceObservedAt: observedAt)
        model.globalSearch.useSyntheticPreview(presenceObservedAt: observedAt)
        model.loadChatList(clear: true)
        model.avatars.bind(TelegramSyntheticAvatarProvider())
        model.peerStatus.useSyntheticPreview()
        model.profilePhotos.bind(TelegramSyntheticProfilePhotoProvider())
        return model
    }
}

/// The preview only renders confirmation. It cannot create paid consent or an Account.
@MainActor private final class TelegramSyntheticSendApprovalProvider: TelegramSendApprovalProviding {
    func capabilities(
        context: TelegramSendContext
    )
        -> Signal<Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>, NoError>
    {
        .single(.success(.init(accountID: context.accountID, chatID: context.chatID, messageFee: .stars(3), secret: nil)))
    }
    func createConsent(
        context: TelegramSendContext, perMessageStars: Int64, consentID: UUID
    )
        -> Signal<Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>, NoError>
    { .single(.failure(.incompatible)) }
}
#endif
