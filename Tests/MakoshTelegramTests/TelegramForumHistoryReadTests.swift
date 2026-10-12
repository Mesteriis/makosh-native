import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func forumReadSeed(_ box: Postbox) -> Signal<PeerId, NoError> {
    box.transaction { transaction in
        let peer = TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(42)),
            accessHash: nil, title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
            participationStatus: .member, info: .group(.init(flags: [])), flags: [.isForum],
            restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [],
            storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
            sendPaidMessageStars: nil, linkedMonoforumId: nil)
        transaction.updatePeersInternal([peer], update: { _, new in new })
        for thread: Int64 in [1, 7] {
            let data = MessageHistoryThreadData(creationDate: 1, isOwnedByMe: false, author: PeerId(1),
                info: .init(title: "Topic", icon: nil, iconColor: 0), incomingUnreadCount: 5, isMarkedUnread: true,
                maxIncomingReadId: 0, maxKnownMessageId: 100, maxOutgoingReadId: 0, isClosed: true, isHidden: false,
                notificationSettings: .defaultSettings, isMessageFeeRemoved: false)
            transaction.setMessageHistoryThreadInfo(peerId: peer.id, threadId: thread,
                info: .init(data: CodableEntry(data)!, summary: .init(totalUnreadCount: 5,
                    isMarkedUnread: true, mutedUntil: nil, maxOutgoingReadId: 0)))
            _ = transaction.addMessages([StoreMessage(id: .init(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: Int32(thread + 10)),
                globallyUniqueId: nil, groupingKey: nil, threadId: thread, timestamp: 100, flags: [.Incoming], tags: [],
                globalTags: [], localTags: [], forwardInfo: nil, authorId: nil, text: "Synthetic", attributes: [], media: [])], location: .Random)
        }
        return peer.id
    }
}

@MainActor final class TelegramForumHistoryReadTests: TelegramSourceFactsIntegrationTestCase {
    func testReadAdmissionKeepsSelectedTopicAndRefusesCrossTopicBoundary() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        let box = try await sourceFactsOpen(path)
        let peer = try await sourceFactsValue(forumReadSeed(box))
        func target(thread: Int64?, message: Int32) -> TelegramHistoryReadTarget {
            .init(context: .init(accountID: 1, chatID: peer.toInt64(), accountContextID: UUID(), historyWindowID: UUID(), threadID: thread),
                index: .init(id: .init(peerId: peer, namespace: Namespaces.Message.Cloud, id: message), timestamp: 100))
        }
        for (thread, message): (Int64?, Int32) in [(1, 11), (7, 17)] {
            let data = try await sourceFactsValue(telegramForumHistoryReadData(postbox: box, target: target(thread: thread, message: message)))
            XCTAssertNotNil(data, "A current closed topic is still readable")
            XCTAssertEqual(data?.threadId, thread); XCTAssertEqual(data?.peerId, peer)
            XCTAssertEqual(data?.isForumPost, true)
        }
        for (thread, message): (Int64?, Int32) in [(nil, 11), (7, 11), (1, 17), (9, 11), (0, 11), (7, 99)] {
            let data = try await sourceFactsValue(telegramForumHistoryReadData(postbox: box, target: target(thread: thread, message: message)))
            XCTAssertNil(data)
        }
    }
}
