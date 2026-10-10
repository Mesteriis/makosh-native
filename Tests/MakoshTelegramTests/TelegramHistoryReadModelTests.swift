import Foundation
import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

#if DEBUG
@MainActor final class TelegramHistoryReadModelTests: XCTestCase {
    private final class Provider: TelegramHistoryReadProvider {
        let accountID: Int64 = -1
        var targets: [TelegramHistoryReadTarget] = []
        func apply(_ target: TelegramHistoryReadTarget, completion: @escaping @MainActor (Bool) -> Void) {
            targets.append(target); completion(true)
        }
    }
    private func selected() throws -> (TelegramModel, Provider, TelegramHistoryReadContext) {
        let model = TelegramModel.syntheticPreview(), provider = Provider()
        model.historyRead.bind(provider)
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        return (model, provider, try XCTUnwrap(model.historyReadContext))
    }
    private func id(_ number: Int) -> String { "synthetic:10001:\(number)" }

    func testVisibleBoundaryIncludesStoredOutgoingAndDoesNotReadWholeLoadedWindow() throws {
        let (model, provider, context) = try selected()
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(81)], context: context, windowIsActive: false))
        XCTAssertTrue(provider.targets.isEmpty)
        XCTAssertTrue(model.markVisibleHistoryRead(messageIDs: [id(81), id(82), "unknown"], context: context, windowIsActive: true))
        XCTAssertEqual(provider.targets.last?.index.id.id, 82)
        XCTAssertLessThan(try XCTUnwrap(provider.targets.last?.index.id.id), 130)
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(81), id(82)], context: context, windowIsActive: true))
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(110), id(112), id(114)], context: context, windowIsActive: true))
        XCTAssertEqual(provider.targets.count, 1)
        XCTAssertTrue(model.markVisibleHistoryRead(messageIDs: [id(118)], context: context, windowIsActive: true))
        XCTAssertEqual(provider.targets.last?.index.id.id, 118)
    }

    func testForeignAccountChatGenerationAndWindowObservationsAreRejected() throws {
        let (model, provider, context) = try selected()
        let wrongContexts = [
            TelegramHistoryReadContext(accountID: 99, chatID: context.chatID, accountContextID: context.accountContextID, historyWindowID: context.historyWindowID),
            TelegramHistoryReadContext(accountID: context.accountID, chatID: 10002, accountContextID: context.accountContextID, historyWindowID: context.historyWindowID),
            TelegramHistoryReadContext(accountID: context.accountID, chatID: context.chatID, accountContextID: UUID(), historyWindowID: context.historyWindowID),
            TelegramHistoryReadContext(accountID: context.accountID, chatID: context.chatID, accountContextID: context.accountContextID, historyWindowID: UUID())
        ]
        for stale in wrongContexts {
            XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(81)], context: stale, windowIsActive: true))
        }
        model.loadOlderMessages()
        XCTAssertNotEqual(model.historyReadContext, context)
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(81)], context: context, windowIsActive: true))
        let current = try XCTUnwrap(model.historyReadContext)
        let visible = try XCTUnwrap(model.messages.last).id
        XCTAssertTrue(model.markVisibleHistoryRead(messageIDs: [visible], context: current, windowIsActive: true))
        model.selectedChatID = 10002
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [visible], context: current, windowIsActive: true))
        let last = try XCTUnwrap(model.historyReadContext)
        model.disconnect()
        XCTAssertNil(model.historyReadContext)
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [visible], context: last, windowIsActive: true))
        XCTAssertEqual(provider.targets.count, 1)
    }

    func testSearchLoadingAndRemovedRowsCannotUseRetainedHistoryIndexes() throws {
        let (model, provider, context) = try selected()
        model.search.messageQuery = "Тестовое сообщение"
        XCTAssertNil(model.historyReadContext)
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(81)], context: context, windowIsActive: true))
        model.search.messageQuery = ""
        let items = model.messages
        model.receiveMessages(items, requestID: context.historyWindowID, previous: nil, next: nil, isLoading: true)
        XCTAssertNil(model.historyReadContext)
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(81)], context: context, windowIsActive: true))
        model.receiveMessages(items, requestID: context.historyWindowID, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.historyReadContext, context)
        model.receiveMessages([], requestID: context.historyWindowID, previous: nil, next: nil, isLoading: false)
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [id(81)], context: context, windowIsActive: true))
        XCTAssertTrue(provider.targets.isEmpty)
    }

    func testSyntheticReadQAStartsInSearchWithoutApplyingReads() {
        let model = TelegramModel.syntheticHistoryReadPreview()
        XCTAssertNotNil(model.selectedChatID)
        XCTAssertTrue(model.search.hasMessageQuery)
        XCTAssertNil(model.historyReadContext)
        XCTAssertEqual(model.syntheticHistoryReadCount, 0)
    }

    private func message(peerNamespace: PeerId.Namespace = Namespaces.Peer.CloudUser,
                         namespace: Int32 = Namespaces.Message.Cloud, flags: MessageFlags = [], id: Int32 = 7) -> Message {
        let peer = PeerId(namespace: peerNamespace, id: ._internalFromInt64Value(42))
        return Message(stableId: 1, stableVersion: 1, id: MessageId(peerId: peer, namespace: namespace, id: id),
            globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 100,
            flags: flags, tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil,
            author: nil, text: "Synthetic boundary", attributes: [], media: [], peers: SimpleDictionary(),
            associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:],
            associatedThreadInfo: nil, associatedStories: [:])
    }

    func testNativeBoundaryUsesExactCloudPeerAndStoredMessageIncludingOutgoing() throws {
        for peerNamespace in [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel] {
            for flags: MessageFlags in [[], [.Incoming]] {
                let item = message(peerNamespace: peerNamespace, flags: flags)
                let index = try XCTUnwrap(telegramHistoryReadIndex(item))
                XCTAssertEqual(index.id, item.id); XCTAssertEqual(index.timestamp, item.timestamp)
            }
        }
        for flags: MessageFlags in [[.Unsent], [.Sending], [.Failed]] {
            XCTAssertNil(telegramHistoryReadIndex(message(flags: flags)))
        }
        for namespace in [Namespaces.Message.Local, Namespaces.Message.ScheduledCloud, Namespaces.Message.ScheduledLocal] {
            XCTAssertNil(telegramHistoryReadIndex(message(namespace: namespace)))
        }
        let secret = message(peerNamespace: Namespaces.Peer.SecretChat)
        XCTAssertNil(telegramHistoryReadIndex(secret))
        XCTAssertNil(telegramHistoryReadIndex(message(id: 0)))
    }

    func testAssociatedOldPeerRetainsNativeIdentityInsideCurrentHistoryWindow() throws {
        let (model, provider, context) = try selected()
        let native = message(peerNamespace: Namespaces.Peer.CloudGroup, flags: [.Incoming])
        XCTAssertNotEqual(native.id.peerId.toInt64(), context.chatID)
        let entry = MessageHistoryEntry(message: native, isRead: false, location: nil, monthLocation: nil,
            attributes: MutableMessageHistoryEntryAttributes(authorIsContact: false))
        // The memory fixture's account sentinel (-1) is not an encoded native
        // PeerId. Use an ordinary cloud identity only for native row mapping.
        let row = TelegramMessage(entry, accountID: 99)
        model.prepareHistoryReadIndexes([entry])
        model.receiveMessages([row], requestID: context.historyWindowID, previous: nil, next: nil, isLoading: false)
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: ["foreign-not-displayed"], context: context, windowIsActive: true))
        XCTAssertTrue(model.markVisibleHistoryRead(messageIDs: [row.id], context: context, windowIsActive: true))
        XCTAssertEqual(provider.targets.last?.index.id, native.id)
        XCTAssertEqual(provider.targets.last?.context.chatID, context.chatID)
        model.selectedChatID = 10002
        XCTAssertFalse(model.markVisibleHistoryRead(messageIDs: [row.id], context: context, windowIsActive: true))
        XCTAssertEqual(provider.targets.count, 1)
    }
}
#endif
