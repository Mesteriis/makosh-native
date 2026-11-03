import XCTest
import Postbox
import TelegramCore
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramWorkspaceFoldersTests: XCTestCase {
    private func user(bot: Bool = false) -> TelegramUser {
        TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)), accessHash: nil,
            firstName: "Synthetic", lastName: "Person", username: nil, phone: nil, photo: [],
            botInfo: bot ? BotUserInfo(flags: [], inlinePlaceholder: nil) : nil, restrictionInfo: nil, flags: [],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }
    private func filter(categories: ChatListFilterPeerCategories = .all, muted: Bool = false, read: Bool = false,
                        archived: Bool = false, include: [PeerId] = [], exclude: [PeerId] = [], pinned: [PeerId] = []) -> ChatListFilter {
        var members = ChatListFilterIncludePeers()
        members.setPeers(include + pinned)
        for id in pinned.reversed() { _ = members.addPinnedPeer(id) }
        return .filter(id: 1, title: .init(text: "Work", entities: [], enableAnimations: false), emoticon: nil,
            data: .init(isShared: false, hasSharedLinks: false, categories: categories, excludeMuted: muted,
                excludeRead: read, excludeArchived: archived, includePeers: members, excludePeers: exclude, color: nil))
    }
    func testFolderProjectionIsProducedOffMain() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox), test: self)
        let received = expectation(description: "native folder projection")
        let observation = Self.nativePage(account).start(next: { @Sendable page in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(page.chats.contains { $0.id == 777 })
            received.fulfill()
        })
        defer { observation.dispose() }
        await fulfillment(of: [received], timeout: 10)
    }
    private nonisolated static func nativePage(_ account: Account) -> Signal<TelegramChatPageProjection, NoError> {
        telegramWorkspaceChatPage(account: account, group: .root, filter: .allChats, anchor: nil)
            |> SwiftSignalKit.filter { $0.chats.contains { $0.id == 777 } } |> take(1)
    }
    func testAllChatsUsesUnfilteredNativeView() {
        XCTAssertNil(telegramWorkspaceFolderPredicate(nil))
        XCTAssertNil(telegramWorkspaceFolderPredicate(.allChats))
    }
    func testCategoriesDistinguishContactsNonContactsAndBots() throws {
        let contacts = try XCTUnwrap(telegramWorkspaceFolderPredicate(filter(categories: .contacts)))
        XCTAssertTrue(contacts.include(user(), false, true, true, nil))
        XCTAssertFalse(contacts.include(user(), false, true, false, nil))
        XCTAssertFalse(contacts.include(user(bot: true), false, true, true, nil))
        let bots = try XCTUnwrap(telegramWorkspaceFolderPredicate(filter(categories: .bots)))
        XCTAssertTrue(bots.include(user(bot: true), false, false, false, nil))
    }
    func testUnreadAndMuteRulesRetainUnreadMentions() throws {
        let p = try XCTUnwrap(telegramWorkspaceFolderPredicate(filter(muted: true, read: true)))
        XCTAssertFalse(p.include(user(), false, false, false, nil))
        XCTAssertFalse(p.include(user(), true, true, false, nil))
        XCTAssertTrue(p.include(user(), true, false, false, true))
        XCTAssertTrue(p.include(user(), false, true, false, false))
        XCTAssertNotNil(p.messageTagSummary)
    }
    func testExplicitMembershipAndExclusionsAreNativeBeforePaging() throws {
        let peer = user()
        let p = try XCTUnwrap(telegramWorkspaceFolderPredicate(filter(categories: [], include: [peer.id])))
        XCTAssertTrue(p.includes(peer: peer, groupId: .root, isRemovedFromTotalUnreadCount: false, isUnread: false, isContact: false, messageTagSummaryResult: nil))
        let excluded = try XCTUnwrap(telegramWorkspaceFolderPredicate(filter(include: [peer.id], exclude: [peer.id])))
        XCTAssertFalse(excluded.includes(peer: peer, groupId: .root, isRemovedFromTotalUnreadCount: false, isUnread: true, isContact: true, messageTagSummaryResult: nil))
    }
    func testArchiveAndPinnedInputsPreserveNativeSemantics() throws {
        let peer = user()
        let p = try XCTUnwrap(telegramWorkspaceFolderPredicate(filter(archived: true, pinned: [peer.id])))
        XCTAssertTrue(p.includeAdditionalPeerGroupIds.isEmpty)
        XCTAssertEqual(p.pinnedPeerIds, [peer.id])
        XCTAssertEqual(telegramWorkspaceFolderPredicate(filter())?.includeAdditionalPeerGroupIds, [Namespaces.PeerGroup.archive])
    }
    func testFolderSelectionUsesAccountFolderIDAndPreservesOpenConversation() {
        let model = TelegramModel.syntheticWorkspaceLayoutPreview()
        XCTAssertEqual(model.workspaceFolderTitle, "Работа")
        XCTAssertEqual(model.chats.count, 5)
        let selected = model.selectedChatID
        model.selectWorkspaceFolder(2)
        XCTAssertEqual(model.workspaceFolderTitle, "Личные")
        XCTAssertEqual(model.chats.map(\.id), [10001, 10006])
        XCTAssertEqual(model.selectedChatID, selected)
        model.selectWorkspaceFolder(999)
        XCTAssertEqual(model.workspaceFolderID, 2)
    }
    func testArchiveAndAllChatsRemainReachable() {
        let model = TelegramModel.syntheticWorkspaceLayoutPreview()
        model.showWorkspaceArchive()
        XCTAssertEqual(model.chatFolder, .archive)
        XCTAssertNil(model.workspaceFolderID)
        XCTAssertEqual(model.chats.count, 1)
        model.selectWorkspaceFolder(nil)
        XCTAssertEqual(model.chatFolder, .inbox)
        XCTAssertEqual(model.chats.count, 7)
        XCTAssertFalse(model.chatPage.canLoadPrevious)
    }
}
