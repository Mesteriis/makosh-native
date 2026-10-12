import XCTest
import Foundation
import SwiftSignalKit
@testable import Postbox
@testable import TelegramCore

private nonisolated func globalSecretSearchPeer() -> TelegramSecretChat {
    TelegramSecretChat(id: PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(21)),
        creationDate: 1,
        regularPeerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)),
        accessHash: 0, role: .creator, embeddedState: .active, messageAutoremoveTimeout: nil)
}

private nonisolated func globalSecretSearchMessageID(_ id: Int32 = 701) -> MessageId {
    MessageId(peerId: globalSecretSearchPeer().id, namespace: Namespaces.Message.SecretIncoming, id: id)
}

private nonisolated func globalSecretSearchSeed(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peer = globalSecretSearchPeer()
        transaction.updatePeersInternal([peer], update: { _, updated in updated })
        _ = transaction.addMessages([StoreMessage(id: globalSecretSearchMessageID(), globallyUniqueId: nil,
            groupingKey: nil, threadId: nil, timestamp: 100, flags: [.Incoming], tags: [],
            globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
            text: "mksecretneedle synthetic", attributes: [], media: [])], location: .Random)
    }
}

private nonisolated func globalSecretSearchSeedPhoto(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        // The native image tagger adds both the dedicated media bit and the photo bit.
        // No attachment bytes or external resources are needed to exercise the stored text index.
        _ = transaction.addMessages([StoreMessage(id: globalSecretSearchMessageID(702), globallyUniqueId: nil,
            groupingKey: nil, threadId: nil, timestamp: 101, flags: [.Incoming], tags: [.photoOrVideo, .photo],
            globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
            text: "mksecretneedle synthetic photo", attributes: [], media: [])], location: .Random)
    }
}

private nonisolated func globalSecretSearchRead(_ box: Postbox, location: SearchMessagesLocation,
    query: String = "mksecretneedle", tags: MessageTags? = nil) -> Signal<[MessageId], NoError> {
    box.transaction { transaction in
        makoshSearchLocalSecretMessages(transaction: transaction, location: location,
            query: query, tags: tags).map(\.id)
    }
}

private nonisolated func globalSecretSearchDirect(_ box: Postbox) -> Signal<[MessageId], NoError> {
    box.transaction { transaction in
        transaction.searchMessages(peerId: globalSecretSearchPeer().id, query: "mksecretneedle", tags: nil).map(\.id)
    }
}

@MainActor final class TelegramGlobalSecretSearchTests: TelegramSourceFactsIntegrationTestCase {
    private func seededPostbox() async throws -> Postbox {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        let box = try await sourceFactsOpen(path)
        try await sourceFactsValue(globalSecretSearchSeed(box))
        // An independent native lookup proves that an empty scope result is not a broken seed/index.
        let direct = try await sourceFactsValue(globalSecretSearchDirect(box))
        XCTAssertEqual(direct, [globalSecretSearchMessageID()])
        return box
    }

    func testGroupsExcludeMatchingIndexedSecretMessages() async throws {
        let box = try await seededPostbox()
        let ids = try await sourceFactsValue(globalSecretSearchRead(box,
            location: .general(scope: .groups, tags: nil, minDate: nil, maxDate: nil)))
        XCTAssertTrue(ids.isEmpty, "Global group search must exclude local secret results before merging")
    }

    func testChannelsContinueExcludingMatchingIndexedSecretMessages() async throws {
        let box = try await seededPostbox()
        let ids = try await sourceFactsValue(globalSecretSearchRead(box,
            location: .general(scope: .channels, tags: nil, minDate: nil, maxDate: nil)))
        XCTAssertTrue(ids.isEmpty)
    }

    func testPrivateEverywhereAndFolderKeepExactIndexedSecretResult() async throws {
        let box = try await seededPostbox()
        let locations: [SearchMessagesLocation] = [
            .general(scope: .privateChats, tags: nil, minDate: nil, maxDate: nil),
            .general(scope: .everywhere, tags: nil, minDate: nil, maxDate: nil),
            .group(groupId: .group(1), tags: nil, minDate: nil, maxDate: nil)
        ]
        for location in locations {
            let ids = try await sourceFactsValue(globalSecretSearchRead(box, location: location))
            XCTAssertEqual(ids, [globalSecretSearchMessageID()])
            let unmatched = try await sourceFactsValue(globalSecretSearchRead(box, location: location,
                query: "mkabsentneedle"))
            XCTAssertTrue(unmatched.isEmpty)
        }
    }

    func testGlobalMediaFilterKeepsOnlyPhotoTaggedSecretMatches() async throws {
        let box = try await seededPostbox()
        try await sourceFactsValue(globalSecretSearchSeedPhoto(box))
        let all = try await sourceFactsValue(globalSecretSearchRead(box,
            location: .general(scope: .privateChats, tags: nil, minDate: nil, maxDate: nil)))
        XCTAssertEqual(Set(all), Set([globalSecretSearchMessageID(701), globalSecretSearchMessageID(702)]))
        let locations: [SearchMessagesLocation] = [
            .general(scope: .privateChats, tags: .photoOrVideo, minDate: nil, maxDate: nil),
            .general(scope: .everywhere, tags: .photoOrVideo, minDate: nil, maxDate: nil)
        ]
        for location in locations {
            let media = try await sourceFactsValue(globalSecretSearchRead(box, location: location, tags: .photoOrVideo))
            XCTAssertEqual(media, [globalSecretSearchMessageID(702)], "A global media search must exclude the plain secret message")
        }
    }
}
