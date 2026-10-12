import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func nativeApprovalUser(_ number: Int64) -> TelegramUser {
    TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(number)),
        accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [],
        botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func nativeApprovalSeed(_ box: Postbox, price: Int64) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([nativeApprovalUser(1), nativeApprovalUser(42)], update: { _, next in next })
        transaction.updatePeerCachedData(peerIds: [nativeApprovalUser(42).id], update: { _, _ in
            CachedUserData().withUpdatedSendPaidMessageStars(.init(value: price, nanos: 0))
        })
        return true
    }
}

@MainActor final class TelegramNativeSendApprovalTests: TelegramSourceFactsIntegrationTestCase {
    // The provider must use its bound Postbox/account and fresh current fee;
    // failed/cancelled later UI work cannot erase an already durable approval.
    func testNativeConfirmationPersistsOnlyExactBoundAccountAndCurrentPrice() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        let box = try await sourceFactsOpen(path)
        _ = try await sourceFactsValue(nativeApprovalSeed(box, price: 7))
        let provider = TelegramNativeSendApprovalProvider(postbox: box, accountID: 1)
        let context = TelegramSendContext(accountID: 1, chatID: 42, threadID: nil,
            submissionRevision: UUID(), messageCount: 2), id = UUID()
        let capabilities = try await sourceFactsValue(provider.capabilities(context: context))
        guard case let .success(current) = capabilities else { return XCTFail("Bound native capability read failed") }
        XCTAssertEqual(current.messageFee, .stars(7))
        let created = try await sourceFactsValue(provider.createConsent(context: context, perMessageStars: 7, consentID: id))
        guard case let .success(consent) = created else { return XCTFail("Bound native confirmation failed") }
        XCTAssertEqual(consent.id, id); XCTAssertEqual(consent.context, context); XCTAssertEqual(consent.totalStars, 14)
        _ = try await sourceFactsValue(nativeApprovalSeed(box, price: 8))
        let changed = try await sourceFactsValue(provider.createConsent(context: context, perMessageStars: 7, consentID: UUID()))
        XCTAssertEqual(changed, .failure(.unavailable))
        let foreign = TelegramSendContext(accountID: 2, chatID: 42, threadID: nil,
            submissionRevision: context.submissionRevision, messageCount: 2), foreignID = UUID()
        let denied = try await sourceFactsValue(provider.createConsent(context: foreign, perMessageStars: 8, consentID: foreignID))
        XCTAssertEqual(denied, .failure(.incompatible))
        let absent = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: foreign, consentID: foreignID))
        XCTAssertEqual(absent, .success(nil))
        let retained = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        XCTAssertEqual(retained, .success(.pending))
    }
}
