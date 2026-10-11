import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func receiptSeed(_ box: Postbox, draft: TelegramPendingUploadDraft) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: draft.accountID, draft: draft, expectedRevision: nil) { return true }
        return false
    }
}
private func receiptValidate(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt) -> Signal<Bool, NoError> {
    box.transaction { receipt.validate(transaction: $0) }
}
private func receiptRaw(_ box: Postbox, account: Int64, chat: Int64, bytes: Data? = nil) -> Signal<Data?, NoError> {
    box.transaction { transaction in
        let key = telegramPendingUploadKey(accountID: account, chatID: chat)
        if let bytes { transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: bytes)) }
        return transaction.getPreferencesEntry(key: key)?.data
    }
}
private func receiptEnqueue(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt, id: MessageId, returnedIDs: [MessageId?]? = nil,
                            placementCount: Int = 0, spoilerCount: Int = 0) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        guard receipt.validate(transaction: transaction) else { return false }
        let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: 100, flags: [.Unsent], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: nil, text: receipt.caption.text,
            attributes: telegramOutgoingTextAttributes(receipt.caption) + (0..<placementCount).map { _ in InvertMediaMessageAttribute() }
                + (0..<spoilerCount).map { _ in MediaSpoilerMessageAttribute() }, media: [])
        _ = transaction.addMessages([message], location: .Random)
        return receipt.acknowledge(transaction: transaction, messageIDs: returnedIDs ?? [id])
    }
}
private func receiptRead(_ box: Postbox, account: Int64, chat: Int64, id: MessageId) -> Signal<(TelegramPendingUploadDraft?, Bool), NoError> {
    box.transaction { transaction in
        let draft = try? telegramPendingUploadRead(transaction: transaction, accountID: account, chatID: chat).get()
        return (draft ?? nil, transaction.getMessage(id) != nil)
    }
}
private func receiptBadIDs(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt, ids: [MessageId?]) -> Signal<Bool, NoError> {
    box.transaction { receipt.acknowledge(transaction: $0, messageIDs: ids) }
}
private func receiptMismatchedMessage(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt, id: MessageId, incoming: Bool, wrongText: Bool, wrongEntities: Bool) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: 100, flags: incoming ? [.Incoming] : [.Unsent], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: nil, text: wrongText ? "different" : receipt.caption.text,
            attributes: wrongEntities ? [] : telegramOutgoingTextAttributes(receipt.caption), media: [])
        _ = transaction.addMessages([message], location: .Random)
        return receipt.acknowledge(transaction: transaction, messageIDs: [id])
    }
}
@MainActor final class TelegramPendingUploadEnqueuePostboxTests: XCTestCase {
    func testNativeSpoilerMustMatchAdmissionAndReceiptSurvivesReopen() async throws {
        for spoiler in [false, true] {
            let path = try root()
            let draft = try pendingUploadMutating(pendingUploadFixture(disposition: .submissionStarted)) {
                $0["mediaSpoiler"] = spoiler; $0["captionAboveMedia"] = true
                var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
                attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
            }
            let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 32)
            do {
                let box = try await open(path); previousBox = box
                let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
                let file = TelegramUploadFile(id: UUID(), name: draft.file.attachment.name, size: draft.file.plaintextByteCount,
                    mode: .photo, pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
                let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
                let wrong = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                    caption: draft.captionInput.formattedText, captionAboveMedia: true, mediaSpoiler: !spoiler)
                let admitted = try await value(receiptValidate(box, receipt: wrong)); XCTAssertFalse(admitted)
                let right = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                    caption: draft.captionInput.formattedText, captionAboveMedia: true, mediaSpoiler: spoiler)
                for count in spoiler ? [0, 2] : [1, 2] {
                    let mismatch = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: 1, spoilerCount: count))
                    XCTAssertFalse(mismatch)
                    let unchanged = try await value(receiptRead(box, account: 1, chat: 42, id: id))
                    XCTAssertEqual(unchanged.0?.disposition, .submissionStarted)
                }
                let accepted = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: 1, spoilerCount: spoiler ? 1 : 0))
                XCTAssertTrue(accepted)
            }
            for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previousBox)
            let reopened = try await open(path)
            let stored = try await value(receiptRead(reopened, account: 1, chat: 42, id: id))
            XCTAssertTrue(stored.1); XCTAssertEqual(stored.0?.mediaSpoiler, spoiler)
            XCTAssertEqual(stored.0?.captionAboveMedia, true)
            XCTAssertEqual(stored.0?.disposition, .accepted(localMessageID: "42:\(Namespaces.Message.Local):32"))
        }
    }
    func testNativePlacementMustMatchAdmissionAndReceiptSurvivesReopen() async throws {
        let path = try root()
        let draft = try pendingUploadMutating(pendingUploadFixture(disposition: .submissionStarted)) {
            $0["captionAboveMedia"] = true
            var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
            attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
        }
        let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 31)
        do {
            let box = try await open(path); previousBox = box
            let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let file = TelegramUploadFile(id: UUID(), name: draft.file.attachment.name, size: draft.file.plaintextByteCount,
                mode: .photo, pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
            let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
            let wrong = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                caption: draft.captionInput.formattedText, captionAboveMedia: false)
            let refused = try await value(receiptEnqueue(box, receipt: wrong, id: id)); XCTAssertFalse(refused)
            let right = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                caption: draft.captionInput.formattedText, captionAboveMedia: true)
            for count in [0, 2] {
                let mismatch = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: count))
                XCTAssertFalse(mismatch)
                let unchanged = try await value(receiptRead(box, account: 1, chat: 42, id: id))
                XCTAssertEqual(unchanged.0?.disposition, .submissionStarted)
            }
            let accepted = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: 1)); XCTAssertTrue(accepted)
        }
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let reopened = try await open(path)
        let stored = try await value(receiptRead(reopened, account: 1, chat: 42, id: id))
        XCTAssertTrue(stored.1); XCTAssertEqual(stored.0?.captionAboveMedia, true)
        XCTAssertEqual(stored.0?.disposition, .accepted(localMessageID: "42:\(Namespaces.Message.Local):31"))
    }
    private weak var previousBox: Postbox?
    private func open(_ root: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted draft fixture")
        var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box)
        let ready = expectation(description: "Both MediaBox stores ready"); ready.expectedFulfillmentCount = 2
        let storage = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let cache = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return result
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }


    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Receipt transaction")
        var result: T?
        let operation = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func receipt(_ draft: TelegramPendingUploadDraft, preparation: UUID? = nil,
                         caption: TelegramFormattedText? = nil, name: String? = nil, size: Int64? = nil,
                         mode: TelegramUploadMode = .file, target: TelegramUploadTarget? = nil) -> TelegramPendingUploadEnqueueReceipt {
        .init(preparationID: preparation ?? draft.id,
            target: target ?? .init(accountID: draft.accountID, chatID: draft.chatID, title: draft.title),
            file: .init(id: UUID(), name: name ?? draft.file.attachment.name, size: size ?? draft.file.plaintextByteCount,
                mode: mode, pixelWidth: nil, pixelHeight: nil,
                url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused")),
            caption: caption ?? draft.captionInput.formattedText)
    }
    private func enqueueThenRelease(path: URL, draft: TelegramPendingUploadDraft, id: MessageId) async throws {
        let box = try await open(path); previousBox = box
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let accepted = try await value(receiptEnqueue(box, receipt: receipt(draft), id: id)); XCTAssertTrue(accepted)
        // Only a transaction result is observed, no upload UI/draft ACK callback.
    }
    func testAtomicReceiptSurvivesReopenBeforeUIAcknowledgementAndDuplicateDoesNotAdd() async throws {
        let path = try root(), draft = try pendingUploadFixture(disposition: .submissionStarted)
        let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 1)
        try await enqueueThenRelease(path: path, draft: draft, id: id)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path)
        let result = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: id))
        let stored = try XCTUnwrap(result.0)
        XCTAssertTrue(result.1)
        XCTAssertEqual(stored.disposition, .accepted(localMessageID: "\(draft.chatID):\(Namespaces.Message.Local):1"))
        XCTAssertNotEqual(stored.revision, draft.revision)
        XCTAssertEqual(stored.captionInput, draft.captionInput); XCTAssertEqual(stored.originalDraft, draft.originalDraft)
        XCTAssertEqual(stored.replyTarget, draft.replyTarget); XCTAssertEqual(stored.file, draft.file)
        let second = MessageId(peerId: id.peerId, namespace: id.namespace, id: 2)
        let duplicate = try await value(receiptEnqueue(box, receipt: receipt(draft), id: second)); XCTAssertFalse(duplicate)
        let absent = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: second))
        XCTAssertFalse(absent.1); XCTAssertEqual(absent.0, stored)
    }
    func testOrphanIncomingAndMismatchedCaptionCannotFabricateAcceptance() async throws {
        let box = try await open(root()), draft = try pendingUploadFixture(disposition: .submissionStarted)
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let raw = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID))
        let orphan = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 20)
        let orphanResult = try await value(receiptBadIDs(box, receipt: receipt(draft), ids: [orphan]))
        XCTAssertFalse(orphanResult)
        let unchanged = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(unchanged, raw)
        for (offset, values) in [(true, false, false), (false, true, false), (false, false, true)].enumerated() {
            let id = MessageId(peerId: orphan.peerId, namespace: orphan.namespace, id: Int32(21 + offset))
            let result = try await value(receiptMismatchedMessage(box, receipt: receipt(draft), id: id,
                incoming: values.0, wrongText: values.1, wrongEntities: values.2))
            XCTAssertFalse(result)
            let retained = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(retained, raw)
        }
    }
    func testRefusalMatrixDoesNotEnqueueOrMutatePointer() async throws {
        let box = try await open(root()), draft = try pendingUploadFixture(disposition: .submissionStarted)
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let raw = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID))
        let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 10)
        let sameTextDifferentEntities = try TelegramFormattedText(text: draft.captionInput.formattedText.text)
        let wrongReply = TelegramMessageActionSource(metadata: .init(peerID: draft.chatID, namespace: Namespaces.Message.Cloud,
            messageID: 1, fingerprint: "synthetic", text: "target", authorID: nil, canReply: true, canEdit: false,
            canForward: false, canDeleteLocally: false, canDeleteForEveryone: false), accountID: draft.accountID, chatID: draft.chatID)
        let normalized = try TelegramFormattedText(text: draft.captionInput.formattedText.text.precomposedStringWithCanonicalMapping,
            entities: draft.captionInput.formattedText.entities)
        let attempts = [receipt(draft, preparation: UUID()), receipt(draft, caption: sameTextDifferentEntities), receipt(draft, caption: normalized),
            receipt(draft, name: "other.txt"), receipt(draft, size: draft.file.plaintextByteCount + 1), receipt(draft, mode: .photo),
            receipt(draft, target: .init(accountID: 9, chatID: draft.chatID, title: "foreign")),
            receipt(draft, target: .init(accountID: draft.accountID, chatID: 99, title: "foreign")),
            receipt(draft, target: .init(accountID: draft.accountID, chatID: draft.chatID, title: draft.title, replySource: wrongReply))]
        for attempt in attempts {
            let result = try await value(receiptEnqueue(box, receipt: attempt, id: id)); XCTAssertFalse(result)
            let bytes = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(bytes, raw)
            let state = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: id)); XCTAssertFalse(state.1)
        }
        let original = try XCTUnwrap(raw)
        let cancelled = try pendingUploadMutating(draft) { $0["disposition"] = ["cancelled": [:]] }
        var cancelledBytes = Data("Makosh.PendingUpload.JSON.v1\n".utf8)
        cancelledBytes.append(try JSONEncoder().encode(cancelled))
        let foreign = try pendingUploadMutating(draft) { $0["accountID"] = 999 }
        var foreignBytes = Data("Makosh.PendingUpload.JSON.v1\n".utf8); foreignBytes.append(try JSONEncoder().encode(foreign))
        for bytes in [Data("unknown-owner".utf8), Data("Makosh.PendingUpload.JSON.v1\n{}".utf8), cancelledBytes, foreignBytes] {
            _ = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID, bytes: bytes))
            let refused = try await value(receiptEnqueue(box, receipt: receipt(draft), id: id)); XCTAssertFalse(refused)
            let retained = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(retained, bytes)
        }
        _ = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID, bytes: original))
        for ids: [MessageId?] in [[], [nil], [id, id],
            [MessageId(peerId: id.peerId, namespace: Namespaces.Message.Cloud, id: 1)],
            [MessageId(peerId: PeerId(99), namespace: Namespaces.Message.Local, id: 1)]] {
            let refused = try await value(receiptBadIDs(box, receipt: receipt(draft), ids: ids)); XCTAssertFalse(refused)
            let retained = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(retained, original)
        }
        // No rollback promise: a malformed nonempty enqueue result leaves the
        // message present, but never fabricates an accepted receipt or retry ACK.
        let uncertain = try await value(receiptEnqueue(box, receipt: receipt(draft), id: id, returnedIDs: []))
        XCTAssertFalse(uncertain)
        let uncertainState = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: id))
        XCTAssertTrue(uncertainState.1); XCTAssertEqual(uncertainState.0?.disposition, .submissionStarted)
    }
}
