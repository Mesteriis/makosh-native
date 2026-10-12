import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func selectedDeleteSeed(_ box: Postbox, changed: Bool = false) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peer = PeerId(7)
        let user = TelegramUser(id: peer, accessHash: nil, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, new in new })
        for n: Int32 in [1, 2, 3] {
            let id = MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: n)
            let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: 55, threadId: nil,
                timestamp: 100, flags: [.CopyProtected], tags: [], globalTags: [], localTags: [],
                forwardInfo: nil, authorId: PeerId(1), text: changed && n == 2 ? "edited" : "original \(n)", attributes: [], media: [])
            if transaction.getMessage(id) != nil { transaction.updateMessage(id) { _ in .update(message) } }
            else { _ = transaction.addMessages([message], location: .Random) }
        }
    }
}
private func selectedDeleteSources(_ box: Postbox, ids: [Int32]) -> Signal<[TelegramMessageActionSource], NoError> {
    box.transaction { transaction in
        ids.compactMap { transaction.getMessage(MessageId(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: $0)) }
            .map { TelegramMessageActionSource(metadata: telegramMessageActionMetadata($0, limits: currentLimitsConfiguration(transaction: transaction)), accountID: 1, chatID: 7) }
    }
}
private func selectedDeleteGroupSeed(_ box: Postbox, admin: Bool) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peer = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7))
        let group = TelegramGroup(id: peer, title: "Synthetic", photo: [], participantCount: 3,
            role: admin ? .creator(rank: nil) : .member, membership: .Member, flags: [],
            defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: admin ? 1 : 2)
        transaction.updatePeersInternal([group], update: { _, new in new })
        let id = MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1)
        if transaction.getMessage(id) == nil {
            _ = transaction.addMessages([StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil,
                threadId: nil, timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [],
                forwardInfo: nil, authorId: PeerId(999), text: "group original", attributes: [], media: [])], location: .Random)
        }
    }
}
private func selectedDeleteGroupSource(_ box: Postbox) -> Signal<TelegramMessageActionSource?, NoError> {
    box.transaction { transaction in
        let peer = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7))
        return transaction.getMessage(MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1)).map {
            TelegramMessageActionSource(metadata: telegramMessageActionMetadata($0, limits: currentLimitsConfiguration(transaction: transaction)),
                accountID: 1, chatID: peer.toInt64())
        }
    }
}
private struct SelectedDeleteState: Sendable {
    let remaining: [Int32]
    let journalTexts: [String]
    let removedIDs: [Int32]
}
private func selectedDeleteState(_ box: Postbox) -> Signal<SelectedDeleteState?, NoError> {
    box.transaction { transaction in
        guard let journal = try? transaction.makoshArchiveJournal(limit: 1000) else { return nil }
        return SelectedDeleteState(remaining: [Int32(1), 2, 3].filter {
            transaction.getMessage(MessageId(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: $0)) != nil
        }, journalTexts: journal.map(\.text), removedIDs: journal.filter(\.removed).map { $0.id.id })
    }
}
@MainActor final class TelegramSelectedMessagesDeletePostboxTests: XCTestCase {
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
    private func request(_ sources: [TelegramMessageActionSource], everyone: Bool = false) throws -> TelegramSelectedMessagesDeleteRequest {
        let selection = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(selection.begin(source: try XCTUnwrap(sources.first), contextID: context))
        for source in sources.dropFirst() {
            XCTAssertTrue(selection.toggle(source: source, sessionID: try XCTUnwrap(selection.session?.id), contextID: context))
        }
        return .init(session: try XCTUnwrap(selection.session), forEveryone: everyone)
    }
    func testAtomicExactSelectedAlbumIDsAndRetentionJournal() async throws {
        let box = try await open(); let _: Void = try await value(selectedDeleteSeed(box))
        let sources = try await value(selectedDeleteSources(box, ids: [1, 3]))
        XCTAssertTrue(sources.allSatisfy { !$0.canForward && $0.canDeleteLocally })
        let request = try request(sources)
        let queued = try await value(telegramDeleteSelectedMessages(postbox: box, stateManager: nil, accountID: 1, request: request))
        XCTAssertTrue(queued)
        let observed = try await value(selectedDeleteState(box))
        let state = try XCTUnwrap(observed)
        XCTAssertEqual(state.remaining, [2], "Unselected album member must survive")
        XCTAssertEqual(state.removedIDs.sorted(), [1, 3])
        XCTAssertTrue(state.journalTexts.contains("original 1")); XCTAssertTrue(state.journalTexts.contains("original 3"))
    }
    func testDeletionAndPriorSnapshotJournalSurviveGenuineReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-delete-reopen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        weak var previous: Postbox?
        do {
            let box = try await open(at: root); previous = box
            let _: Void = try await value(selectedDeleteSeed(box))
            let sources = try await value(selectedDeleteSources(box, ids: [1, 3]))
            let queued = try await value(telegramDeleteSelectedMessages(postbox: box, stateManager: nil,
                accountID: 1, request: try request(sources)))
            XCTAssertTrue(queued)
        }
        for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previous, "Prior Postbox must be released before reopening")
        guard previous == nil else { return }
        let reopened = try await open(at: root)
        let observed = try await value(selectedDeleteState(reopened)), state = try XCTUnwrap(observed)
        XCTAssertEqual(state.remaining, [2]); XCTAssertEqual(state.removedIDs.sorted(), [1, 3])
        XCTAssertTrue(state.journalTexts.contains("original 1")); XCTAssertTrue(state.journalTexts.contains("original 3"))
    }
    func testFreshAdminPermissionLossRejectsWholeEveryoneBatch() async throws {
        let box = try await open(); let _: Void = try await value(selectedDeleteGroupSeed(box, admin: true))
        let initial = try await value(selectedDeleteGroupSource(box)), source = try XCTUnwrap(initial)
        XCTAssertTrue(source.canDeleteForEveryone)
        let request = try request([source], everyone: true)
        let _: Void = try await value(selectedDeleteGroupSeed(box, admin: false))
        let updated = try await value(selectedDeleteGroupSource(box)), fresh = try XCTUnwrap(updated)
        XCTAssertEqual(source.fingerprint, fresh.fingerprint, "Peer permissions are separate from message version")
        XCTAssertFalse(fresh.canDeleteForEveryone)
        let queued = try await value(telegramDeleteSelectedMessages(postbox: box, stateManager: nil, accountID: 1, request: request))
        XCTAssertFalse(queued)
        let surviving = try await value(selectedDeleteGroupSource(box)); XCTAssertNotNil(surviving)
    }
    func testChangedMissingAndForeignBatchRefusesAllWithoutPartialRemoval() async throws {
        for mode in 0..<3 {
            let box = try await open(); let _: Void = try await value(selectedDeleteSeed(box))
            var sources = try await value(selectedDeleteSources(box, ids: [1, 2]))
            if mode == 0 { let _: Void = try await value(selectedDeleteSeed(box, changed: true)) }
            if mode == 1 {
                let original = sources[1]
                sources[1] = .init(accountID: 1, chatID: 7, peerID: 7, namespace: 0, messageID: 999,
                    fingerprint: original.fingerprint, text: original.text, canReply: true, canEdit: false,
                    canForward: true, canDeleteLocally: true, canDeleteForEveryone: false)
            }
            let request = try request(sources)
            let queued = try await value(telegramDeleteSelectedMessages(postbox: box, stateManager: nil,
                accountID: mode == 2 ? 2 : 1, request: request))
            XCTAssertFalse(queued)
            let observed = try await value(selectedDeleteState(box))
        let state = try XCTUnwrap(observed)
            XCTAssertEqual(state.remaining, [1, 2, 3]); XCTAssertTrue(state.removedIDs.isEmpty)
        }
    }
}
