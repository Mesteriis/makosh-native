import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func selectedCopySeed(_ box: Postbox, changed: Bool = false, protected: Bool = false) -> Signal<Void, NoError> {
    box.transaction { tx in
        for raw: Int64 in [7, 777000] {
            let peer = PeerId(raw)
            let user = TelegramUser(id: peer, accessHash: nil, firstName: "Synthetic", lastName: nil,
                username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
                emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
                profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            tx.updatePeersInternal([user], update: { _, new in new })
            for n: Int32 in [1,2] {
                let id = MessageId(peerId: peer, namespace: 0, id: n)
                let attrs: [MessageAttribute] = n == 1 ? [TextEntitiesMessageAttribute(entities: [.init(range: 0..<6, type: .Spoiler)])] : []
                let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: 55, threadId: nil,
                    timestamp: 100, flags: protected && n == 2 ? [.Incoming,.CopyProtected] : [.Incoming],
                    tags: [], globalTags: [], localTags: [],
                    forwardInfo: n == 2 ? StoreMessageForwardInfo(authorId: nil, sourceId: nil, sourceMessageId: nil, date: 50, authorSignature: "Forwarded Synthetic", psaType: nil, flags: []) : nil, authorId: peer,
                    text: changed && n == 2 ? "edited" : n == 1 ? "secret 12345" : "second", attributes: attrs, media: [])
                if tx.getMessage(id) == nil { _ = tx.addMessages([message], location: .Random) }
                else { tx.updateMessage(id) { _ in .update(message) } }
            }
        }
    }
}
private func selectedCopySources(_ box: Postbox, peer: Int64 = 7) -> Signal<[TelegramMessageActionSource], NoError> {
    box.transaction { tx in [Int32(2),1].compactMap { tx.getMessage(MessageId(peerId: PeerId(peer), namespace: 0, id: $0)) }.map {
        .init(metadata: telegramMessageActionMetadata($0), accountID: 1, chatID: peer)
    } }
}
@MainActor final class TelegramSelectedMessagesCopyPostboxTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let ready = expectation(description: "Synthetic range transaction")
        var result: T?
        let lease = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; ready.fulfill() })
        defer { lease.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func open(at existingRoot: URL? = nil) async throws -> Postbox {
        initializeAccountManagement()
        let root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("makosh-delete-test-" + UUID().uuidString)
        if existingRoot == nil {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
        }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 31, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 32, count: 16)))
        let ready = expectation(description: "Encrypted range Postbox")
        var result: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(box) = $0 { result = box; ready.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        let box = try XCTUnwrap(result), stores = expectation(description: "Both media stores initialized")
        stores.expectedFulfillmentCount = 2
        let a = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        let b = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        defer { a.dispose(); b.dispose() }
        await fulfillment(of: [stores], timeout: 20)
        return box
    }
    private func request(_ sources: [TelegramMessageActionSource]) throws -> TelegramSelectedMessagesCopyRequest {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: try XCTUnwrap(sources.first), contextID: context))
        for source in sources.dropFirst() { XCTAssertTrue(c.toggle(source: source, sessionID: try XCTUnwrap(c.session?.id), contextID: context)) }
        return .init(session: try XCTUnwrap(c.session))
    }
    func testEncryptedCacheNativeOrderSpoilerAndServiceCodeMasking() async throws {
        let box = try await open(); let _: Void = try await value(selectedCopySeed(box))
        for peer: Int64 in [7,777000] {
            let sources = try await value(selectedCopySources(box, peer: peer))
            let items = try await value(telegramSelectedCopyItems(postbox: box, accountID: 1, request: try request(sources)))
            let text = telegramSelectedCopyText(try XCTUnwrap(items))
            XCTAssertFalse(text.contains("secret")); XCTAssertTrue(text.contains("> Forwarded Synthetic:"))
            XCTAssertTrue(text.contains(peer == 777000 ? "██████ █████" : "██████ 12345"))
            XCTAssertLessThan(try XCTUnwrap(text.range(of: "██████")?.lowerBound), try XCTUnwrap(text.range(of: "second")?.lowerBound))
        }
    }
    func testChangedProtectedMissingForeignAndUnverifiedMigrationRefuseWholeBatch() async throws {
        for mode in 0..<5 {
            let box = try await open(); let _: Void = try await value(selectedCopySeed(box))
            var sources = try await value(selectedCopySources(box))
            if mode == 0 { let _: Void = try await value(selectedCopySeed(box, changed: true)) }
            if mode == 1 { let _: Void = try await value(selectedCopySeed(box, protected: true)) }
            if mode == 2 {
                let old = sources[0]
                sources[0] = .init(accountID: 1, chatID: 7, peerID: 7, namespace: 0, messageID: 999,
                    fingerprint: old.fingerprint, text: old.text, canReply: true, canEdit: false, canForward: true,
                    canDeleteLocally: true, canDeleteForEveryone: false, canCopy: true)
            }
            if mode == 4 { sources = sources.map { .init(metadata: $0.metadata, accountID: 1, chatID: 8) } }
            let result = try await value(telegramSelectedCopyItems(postbox: box, accountID: mode == 3 ? 2 : 1, request: try request(sources)))
            XCTAssertNil(result, "No partial copied content on one invalid member")
        }
    }
}
