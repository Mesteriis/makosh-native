import XCTest
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

private nonisolated func groupJournalCapture(_ box: Postbox) -> Signal<(texts: [String], removed: [Bool], incoming: [Bool], nativeHistoryEmpty: Bool)?, NoError> {
    box.transaction { transaction in
        let peer = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(10))
        let id = MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 7)
        func message(_ text: String) -> StoreMessage {
            .init(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 1000,
                flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
                authorId: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(8)), text: text, attributes: [], media: [])
        }
        do {
            try transaction.makoshArchiveObserve(message: message("Before edit"), removed: false)
            try transaction.makoshArchiveObserve(message: message("After edit"), removed: false)
            try transaction.makoshArchiveObserve(message: message("After edit"), removed: true)
            let values = try transaction.makoshArchiveJournal(limit: 10)
            return (values.map(\.text), values.map(\.removed), values.map { $0.flags.contains(.Incoming) }, transaction.getMessage(id) == nil)
        } catch { return nil }
    }
}
private nonisolated func groupJournalInvalid(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let peer = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(10))
        let partial = StoreMessage(peerId: peer, namespace: Namespaces.Message.Cloud, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: 1000, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil, text: "No stable ID", attributes: [], media: [])
        do { try transaction.makoshArchiveObserve(message: partial, removed: true); return false }
        catch { return (try? transaction.makoshArchiveJournal(limit: 10).isEmpty) == true }
    }
}
private nonisolated func groupAdminApiMessage(_ text: String, channel: Int64 = 10, protected: Bool = false) -> Api.Message {
    .message(flags: protected ? 1 << 26 : 0, flags2: 0, id: 7, fromId: .peerUser(userId: 8), fromBoostsApplied: nil,
        peerId: .peerChannel(channelId: channel), savedPeerId: nil, fwdFrom: nil, viaBotId: nil, viaBusinessBotId: nil,
        replyTo: nil, date: 1000, message: text, media: nil, replyMarkup: nil, entities: nil, views: nil, forwards: nil,
        replies: nil, editDate: nil, postAuthor: nil, groupedId: nil, reactions: nil, restrictionReason: nil,
        ttlPeriod: nil, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil, suggestedPost: nil)
}
private nonisolated func groupAdminPacket(_ box: Postbox, foreign: Bool = false, empty: Bool = false) -> Signal<(accepted: Bool, texts: [String], protected: Bool, unavailable: Bool), NoError> {
    box.transaction { transaction in
        let account = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(101))
        let peer = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(10))
        let events: [Api.ChannelAdminLogEvent]
        if empty {
            events = [.channelAdminLogEvent(id: 1, date: 1000, userId: 8,
                action: .channelAdminLogEventActionDeleteMessage(message: .messageEmpty(flags: 0, id: 7, peerId: .peerChannel(channelId: 10))))]
        } else {
            events = [.channelAdminLogEvent(id: 1, date: 1000, userId: 8,
                action: .channelAdminLogEventActionEditMessage(prevMessage: groupAdminApiMessage("Before"), newMessage: groupAdminApiMessage("After", protected: true))),
                .channelAdminLogEvent(id: 2, date: 1001, userId: 8,
                action: .channelAdminLogEventActionDeleteMessage(message: groupAdminApiMessage("After", channel: foreign ? 11 : 10, protected: true)))]
        }
        let result = makoshGroupAdminObservations(transaction: transaction, accountPeerId: account, peerId: peer, events: events)
        let journal = (try? transaction.makoshArchiveJournal(limit: 10)) ?? []
        return (result != nil, journal.map(\.text), result?[1]?.copyProtected ?? false, result?[1]?.unavailable ?? false)
    }
}
@MainActor final class TelegramGroupAdminArchiveTests: XCTestCase {
    func testAdminObservationsRetainAllVersionsWithoutResurrectingNativeHistory() async throws {
        let box = try await telegramDataPostbox(test: self)
        let result = try await telegramDataValue(groupJournalCapture(box), test: self)
        let value = try XCTUnwrap(result)
        XCTAssertEqual(value.texts, ["Before edit", "After edit", "After edit"])
        XCTAssertEqual(value.removed, [false, false, true]); XCTAssertEqual(value.incoming, [true, true, true])
        XCTAssertTrue(value.nativeHistoryEmpty)
    }
    func testTypedAdminPacketCapturesEditDeleteAndProtection() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(groupAdminPacket(box), test: self)
        XCTAssertTrue(value.accepted); XCTAssertEqual(value.texts, ["Before", "After", "After"]); XCTAssertTrue(value.protected)
    }
    func testForeignMessageRejectsWholePacketBeforeJournalAppend() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(groupAdminPacket(box, foreign: true), test: self)
        XCTAssertFalse(value.accepted); XCTAssertTrue(value.texts.isEmpty)
    }
    func testMissingRemoteContentNeverCreatesAFakeEmptyArchivedVersion() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(groupAdminPacket(box, empty: true), test: self)
        XCTAssertTrue(value.accepted); XCTAssertTrue(value.unavailable); XCTAssertTrue(value.texts.isEmpty)
    }
    func testObservationWithoutStableMessageIdentityDoesNotEnterJournal() async throws {
        let box = try await telegramDataPostbox(test: self)
        let valid = try await telegramDataValue(groupJournalInvalid(box), test: self)
        XCTAssertTrue(valid)
    }
}
