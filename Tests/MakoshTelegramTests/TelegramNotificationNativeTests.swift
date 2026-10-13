import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func seedNotificationFixture(_ box: Postbox, hide: Bool = false, mute: Bool = false, read: Bool = false, captionOnLast: Bool = false, forwarded: Bool = false) -> Signal<Void, NoError> {
    box.transaction { tx in
        let peer = PeerId(777000)
        let user = TelegramUser(id: peer, accessHash: nil, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        tx.updatePeersInternal([user], update: { _, new in new })
        tx.resetIncomingReadStates([peer: [0: .idBased(maxIncomingReadId: read ? 2 : 0,
            maxOutgoingReadId: 0, maxKnownId: 2, count: read ? 0 : 2, markedUnread: false)]])
        tx.updateCurrentPeerNotificationSettings([peer: TelegramPeerNotificationSettings(
            muteState: mute ? .muted(until: Int32.max) : .unmuted, messageSound: .none,
            displayPreviews: hide ? .hide : .show, storySettings: .default)])
        for n: Int32 in [1,2] {
            let id = MessageId(peerId: peer, namespace: 0, id: n)
            let item = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: forwarded ? nil : 55, threadId: nil,
                timestamp: 1_999, flags: [.Incoming], tags: [], globalTags: [], localTags: [],
                forwardInfo: forwarded ? .init(authorId: nil, sourceId: nil, sourceMessageId: nil, date: 1_900, authorSignature: "Synthetic", psaType: nil, flags: []) : nil,
                authorId: peer, text: forwarded ? (n == 1 ? "Forwarded first" : "Forwarded second") : captionOnLast && n == 1 ? "" : "secret 12345",
                attributes: forwarded || (captionOnLast && n == 1) ? [] : [TextEntitiesMessageAttribute(entities: [.init(range: 0..<6, type: .Spoiler)])], media: [])
            if tx.getMessage(id) == nil { _ = tx.addMessages([item], location: .Random) }
            else { tx.updateMessage(id) { _ in .update(item) } }
        }
    }
}
@MainActor final class TelegramNotificationNativeTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Synthetic notification transaction")
        var result: T?
        let d = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { d.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func open() async throws -> Postbox {
        initializeAccountManagement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-notification-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 41, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 42, count: 16)))
        let opened = expectation(description: "Encrypted synthetic notification cache")
        var result: Postbox?
        let d = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: .init(forceEncryptionIfNoSet: true, key: key, salt: salt), timestampForAbsoluteTimeBasedOperations: 1,
            isMainProcess: true, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(box) = $0 { result = box; opened.fulfill() } })
        defer { d.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let box = try XCTUnwrap(result)
        _ = try await value(box.mediaBox.storageBox.all()); _ = try await value(box.mediaBox.cacheStorageBox.all())
        return box
    }
    func testNativeCacheResolutionRespectsMuteReadPreviewSoundAndMasksServiceCodes() async throws {
        let box = try await open()
        let ids = [Int32(1),2].map { MessageId(peerId: PeerId(777000), namespace: 0, id: $0) }
        let _: Void = try await value(seedNotificationFixture(box))
        let events = try await value(telegramNotificationEvents(postbox: box, accountID: 1, ids: ids))
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.peerID, 777000); XCTAssertTrue(event.serviceCodes); XCTAssertTrue(event.serverSilent)
        XCTAssertEqual(telegramNotificationContent(event, preferences: .init(), environment: .init(now: Date(timeIntervalSince1970: 2_000)))?.body, "██████ █████")
        let _: Void = try await value(seedNotificationFixture(box, hide: true))
        let hidden = try await value(telegramNotificationEvents(postbox: box, accountID: 1, ids: ids))
        XCTAssertEqual(hidden.first?.serverPreviews, false)
        let _: Void = try await value(seedNotificationFixture(box, mute: true))
        let muted = try await value(telegramNotificationEvents(postbox: box, accountID: 1, ids: ids))
        XCTAssertTrue(muted.isEmpty)
        let _: Void = try await value(seedNotificationFixture(box, read: true))
        let read = try await value(telegramNotificationEvents(postbox: box, accountID: 1, ids: ids))
        XCTAssertTrue(read.isEmpty)
    }
    func testNativeUnreadCountersUseFilteredWholeAccountDataAndSeparateBotGroupChannelTags() {
        let state = ChatListTotalUnreadState(absoluteCounters: [.contact: .init(messageCount: 900, chatCount: 90)],
            filteredCounters: [.contact: .init(messageCount: 2, chatCount: 1), .nonContact: .init(messageCount: 3, chatCount: 1),
                .bot: .init(messageCount: 4, chatCount: 1), .group: .init(messageCount: 5, chatCount: 2),
                .channel: .init(messageCount: 6, chatCount: 3)])
        let counts = telegramNotificationUnreadCounts(state)
        XCTAssertEqual(counts[.personal], .init(messages: 9, chats: 3))
        XCTAssertEqual(counts[.groups], .init(messages: 5, chats: 2))
        XCTAssertEqual(counts[.channels], .init(messages: 6, chats: 3))
    }
    func testRepeatedAlbumMembersDoNotConsumeUniqueIncomingBatchLimit() async throws {
        let box = try await open()
        let _: Void = try await value(seedNotificationFixture(box))
        let ids = Array(repeating: [Int32(1),2], count: 550).flatMap { $0 }.map {
            MessageId(peerId: PeerId(777000), namespace: 0, id: $0)
        }
        let events = try await value(telegramNotificationEvents(postbox: box, accountID: 1, ids: ids))
        XCTAssertEqual(events.count, 1)
    }
    func testAlbumUsesFirstNonemptyResolvedCaptionIndependentlyOfArrivingMember() async throws {
        let box = try await open()
        let _: Void = try await value(seedNotificationFixture(box, captionOnLast: true))
        let ids = [Int32(1),2].map { MessageId(peerId: PeerId(777000), namespace: 0, id: $0) }
        for order in [ids, ids.reversed().map { $0 }] {
            let events = try await value(telegramNotificationEvents(postbox: box, accountID: 1, ids: order))
            XCTAssertEqual(events.count, 1)
            if let event = events.first {
                XCTAssertEqual(telegramNotificationContent(event, preferences: .init(), environment: .init(now: Date(timeIntervalSince1970: 2_000)))?.body, "██████ █████")
            }
        }
    }
    func testForwardedNonalbumMessagesKeepTheirOwnDistinctText() async throws {
        let box = try await open()
        let _: Void = try await value(seedNotificationFixture(box, forwarded: true))
        let ids = [Int32(1),2].map { MessageId(peerId: PeerId(777000), namespace: 0, id: $0) }
        let events = try await value(telegramNotificationEvents(postbox: box, accountID: 1, ids: ids))
        XCTAssertEqual(events.map { telegramNotificationContent($0, preferences: .init(), environment: .init(now: Date(timeIntervalSince1970: 2_000)))?.body }, ["Forwarded first", "Forwarded second"])
    }
}
