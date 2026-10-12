import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func aliasNativeUser(_ id: Int64) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}

private nonisolated func aliasNativeSeed(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([aliasNativeUser(1), aliasNativeUser(42)], update: { _, new in new })
        return true
    }
}

private nonisolated func aliasNativeRead(_ box: Postbox, ids: [MessageId]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0) } }
}

private nonisolated func aliasNativeEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
                                          messages: [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { 100 }) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(42), messages: messages, transactionAdmission: admission, transactionCommit: commit)
    }
}

@MainActor final class TelegramSourceFactsAliasNativeQueueTests: TelegramSourceFactsIntegrationTestCase {
    // Catches replacing retained alias/probe facts or bytes during persistence, restoration and native local admission.
    func testPriorAliasesRestoreAndQueueExactFilesUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let cases: [(String, String, TelegramUploadSourceFacts.ImageProbe)] = [
                ("old.PSD", "image/vnd.adobe.photoshop", .decoded(width: 40, height: 80)),
                ("old.DCR", "image/x-kodak-dcr", .decoded(width: 40, height: 80)),
                ("old.BM", "application/octet-stream", .notImage),
                ("old.ICNS", "application/octet-stream", .notImage)
            ]
            var items: [TelegramUploadBatchItem] = [], expectedBytes: [Data] = []
            defer { items.forEach { try? $0.discard() } }
            for (name, mime, probe) in cases {
                let source = fixture.root.appendingPathComponent(name)
                try writeUploadVideoCoverFixture(source)
                expectedBytes.append(try Data(contentsOf: source))
                let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
                items.append(.init(id: raw.id, file: raw, sourceFacts: try sourceFacts(raw, mime: mime, image: probe)))
                try FileManager.default.removeItem(at: source)
            }
            let expectedFacts = items.map(\.sourceFacts), store = fixture.session(box), id = UUID()
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
            let prepared = try await sourceFactsLoad(store)
            items.forEach { try? $0.discard() }
            let restored = try await fixture.session(box).restoreItems(draft: prepared)
            defer { restored.forEach { try? $0.discard() } }
            XCTAssertEqual(restored.map(\.sourceFacts), expectedFacts)
            XCTAssertEqual(try restored.map { try Data(contentsOf: $0.file.url) }, expectedBytes)
            try await store.save(preparationID: id, chatID: 42, captionInput: .empty, disposition: .submissionStarted)
            let draft = try await sourceFactsLoad(store)
            let seeded = try await sourceFactsValue(aliasNativeSeed(box)); XCTAssertTrue(seeded)
            let done = expectation(description: "Retained alias files accepted by native local queue")
            var accepted: [TelegramUploadQueueID]?
            let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: restored, draft: draft,
                target: fixture.target, enqueue: { receipt, messages in
                    aliasNativeEnqueue(box, receipt: receipt, messages: messages)
                }, receive: { event in
                    switch event {
                    case let .accepted(ids): accepted = ids; done.fulfill()
                    case .rejected, .uncertain: XCTFail("Reviewed retained aliases must queue"); done.fulfill()
                    default: break
                    }
                })
            defer { submission.stop() }
            await fulfillment(of: [done], timeout: 20)
            guard let accepted else { continue }
            let saved = try await sourceFactsLoad(store)
            XCTAssertEqual(saved.items, prepared.items)
            XCTAssertEqual(saved.disposition, .acceptedBatch(messageIDs: accepted))
            let messages = try await sourceFactsValue(aliasNativeRead(box, ids: accepted.map(\.nativeID)))
            XCTAssertEqual(messages.count, 4)
            for (index, message) in messages.enumerated() {
                let file = try XCTUnwrap(message.media.first as? TelegramMediaFile)
                let cached = try await sourceFactsValue(box.mediaBox.resourceData(file.resource, pathExtension: nil,
                    option: .complete(waitUntilFetchStatus: false)))
                XCTAssertTrue(cached.complete); XCTAssertEqual(cached.offset, 0)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cached.path)), expectedBytes[index])
            }
            XCTAssertEqual(prepared.items.map { $0.file.state }, Array(repeating: enabled ? .stored : .local, count: 4))
            XCTAssertEqual(try fixture.localRecords().count, enabled ? 0 : 4)
        }
    }
}
