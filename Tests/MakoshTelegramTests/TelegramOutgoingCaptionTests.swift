import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func seedCaptionMention(_ box: Postbox, id: PeerId, hash: TelegramPeerAccessHash?) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peer = TelegramUser(id: id, accessHash: hash, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([peer], update: { _, new in new })
    }
}

@MainActor final class TelegramOutgoingCaptionTests: XCTestCase {
    func testEmptyWhitespaceBoundsAndUnsupportedKinds() throws {
        XCTAssertTrue(telegramFormattedCaptionCanSend(try TelegramFormattedText(text: "")))
        let whitespace = try TelegramFormattedText(text: " \n", entities: [.init(offset: 0, length: 2, kind: .bold)])
        XCTAssertTrue(telegramFormattedCaptionCanSend(whitespace))
        XCTAssertTrue(telegramFormattedCaptionCanSend(try TelegramFormattedText(text: String(repeating: "😀", count: 512))))
        XCTAssertFalse(telegramFormattedCaptionCanSend(try TelegramFormattedText(text: String(repeating: "😀", count: 513))))
        for kind: TelegramTextEntityKind in [.unknown, .custom(type: 9), .phoneNumber,
                                             .customEmoji(stickerPack: nil, fileID: 10)] {
            XCTAssertFalse(telegramFormattedCaptionCanSend(try TelegramFormattedText(text: "x", entities: [.init(offset: 0, length: 1, kind: kind)])))
        }
    }
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Caption transaction")
        var result: T?
        let disposable = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { disposable.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    func testProductionValidationOnEncryptedPostboxRejectsUnresolvedMentions() async throws {
        initializeAccountManagement()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 21, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 22, count: 16)))
        let opened = expectation(description: "Encrypted synthetic caption Postbox")
        var box: Postbox?
        let opening = (openPostbox(basePath: directory.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let postbox = try XCTUnwrap(box)
        let ready = expectation(description: "Both MediaBox stores")
        ready.expectedFulfillmentCount = 2
        let storage = (postbox.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let cache = (postbox.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(123))
        let caption = try TelegramFormattedText(text: "Mention", entities: [.init(offset: 0, length: 7, kind: .textMention(peerID: id.toInt64()))])
        let missing = try await value(telegramValidateOutgoingCaption(postbox: postbox, formatted: caption))
        XCTAssertFalse(missing)
        _ = try await value(seedCaptionMention(postbox, id: id, hash: nil))
        let hashless = try await value(telegramValidateOutgoingCaption(postbox: postbox, formatted: caption))
        XCTAssertFalse(hashless)
        _ = try await value(seedCaptionMention(postbox, id: id, hash: .personal(456)))
        let resolved = try await value(telegramValidateOutgoingCaption(postbox: postbox, formatted: caption))
        XCTAssertTrue(resolved)
        let empty = try await value(telegramValidateOutgoingCaption(postbox: postbox, formatted: TelegramFormattedText(text: "")))
        XCTAssertTrue(empty)
    }
}
