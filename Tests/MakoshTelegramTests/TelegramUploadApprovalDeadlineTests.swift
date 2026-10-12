import XCTest
import Foundation
import TelegramCore
@testable import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramUploadApprovalDeadlineTests: TelegramSourceFactsIntegrationTestCase {
    // Catches a network deadline cancelling the user's durable preparation while a consent sheet is open.
    func testHumanApprovalWaitOutlivesSubmissionDeadlineWithoutCancellingTheDraft() async throws {
        for batch in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            _ = try await sourceFactsValue(approvalDeadlineSeed(box))
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: false)
            let source = fixture.root.appendingPathComponent("approval.txt")
            try Data("retained approval payload".utf8).write(to: source)
            let store = fixture.session(box), provider = ApprovalDeadlineProvider()
            let controller = TelegramUploadController(submissionTimeout: .milliseconds(40))
            defer { controller.clear(); provider.stop() }
            controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            let input = try TelegramComposerInput(formattedText: .init(text: "retained caption"))
            if batch {
                controller.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false,
                    target: fixture.target, captionInput: input, captionPolicy: try .init(maximumUTF16Count: 1024))
            } else {
                controller.prepare(source: source, mode: .file, target: fixture.target, captionInput: input)
            }
            try await waitUntil { controller.phase == .ready && !controller.isRecoveryBusy }
            let preparationID = try XCTUnwrap(controller.preparationContextID)
            controller.send(contextID: preparationID)
            try await waitUntil { provider.hasReceiver }
            let before = try await sourceFactsLoad(store)
            XCTAssertEqual(before.disposition, .submissionStarted)
            let frozen = try encoded(before)
            try await Task.sleep(for: .milliseconds(140))
            XCTAssertEqual(controller.phase, .storing)
            XCTAssertEqual(controller.preparationContextID, preparationID)
            XCTAssertEqual(controller.captionInput, input)
            XCTAssertTrue(controller.canCancel)
            XCTAssertFalse(controller.canSend)
            let waiting = try await sourceFactsLoad(store)
            XCTAssertEqual(try encoded(waiting), frozen)
            controller.cancelPreparation()
            try await waitUntil { !controller.isCancellationBusy }
            let cancelled = try await sourceFactsLoad(store)
            XCTAssertEqual(cancelled.disposition, .cancelled)
            XCTAssertEqual(cancelled.id, preparationID)
        }
    }

    // Catches pausing the deadline permanently instead of starting a fresh budget at the actual enqueue boundary.
    func testDeadlineRestartsAfterApprovalAndKeepsTheUnknownQueueResultRecoverable() async throws {
        for batch in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            _ = try await sourceFactsValue(approvalDeadlineSeed(box))
            let source = fixture.root.appendingPathComponent("committed.txt")
            try Data("committed payload".utf8).write(to: source)
            let store = fixture.session(box), provider = ApprovalDeadlineProvider()
            let controller = TelegramUploadController(submissionTimeout: .milliseconds(40))
            defer { controller.clear(); provider.stop() }
            controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            if batch {
                controller.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false,
                    target: fixture.target, captionInput: .empty, captionPolicy: try .init(maximumUTF16Count: 1024))
            } else {
                controller.prepare(source: source, mode: .file, target: fixture.target, captionInput: .empty)
            }
            try await waitUntil { controller.phase == .ready && !controller.isRecoveryBusy }
            let preparationID = try XCTUnwrap(controller.preparationContextID)
            controller.send(contextID: preparationID)
            try await waitUntil { provider.hasReceiver }
            let before = try await sourceFactsLoad(store), frozen = try encoded(before)
            try await Task.sleep(for: .milliseconds(140))
            guard controller.phase == .storing else {
                XCTFail("A human approval delay must retain the pending preparation")
                continue
            }
            provider.commit()
            XCTAssertEqual(controller.phase, .enqueuing)
            XCTAssertFalse(controller.canCancel)
            try await waitUntil { controller.phase == .uncertain }
            XCTAssertEqual(controller.preparationContextID, preparationID)
            XCTAssertTrue(controller.showsPreparationPreview)
            XCTAssertFalse(controller.canSend)
            let unknown = try await sourceFactsLoad(store)
            XCTAssertEqual(try encoded(unknown), frozen)
            controller.cancelPreparation()
            XCTAssertEqual(controller.phase, .uncertain)
            provider.accept(postbox: box)
            try await waitUntil("Late ACK after timeout, batch=\(batch)") {
                if case .queued = controller.phase { return true }; return false
            }
            let accepted = try await sourceFactsLoad(store)
            if batch {
                guard case let .acceptedBatch(ids) = accepted.disposition else {
                    XCTFail("The native batch receipt must commit before its late ACK")
                    continue
                }
                XCTAssertEqual(ids.count, 1)
                XCTAssertEqual(ids.first?.peerID, 42)
                XCTAssertEqual(ids.first?.namespace, Namespaces.Message.Local)
                let queued = try await sourceFactsValue(approvalDeadlineQueued(box, ids: ids))
                XCTAssertTrue(queued)
            } else {
                XCTAssertEqual(accepted.disposition, .accepted(localMessageID: "approval-accepted"))
            }
        }
    }

    private func encoded(_ value: TelegramPendingUploadDraft) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func waitUntil(_ transition: String = "Upload lifecycle", _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("\(transition) did not finish")
        throw ApprovalDeadlineFailure.timeout
    }
}

private enum ApprovalDeadlineFailure: Error { case timeout }

@MainActor private final class ApprovalDeadlineProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    private var single: (@MainActor (TelegramUploadEvent) -> Void)?
    private var batch: (@MainActor (TelegramUploadBatchEvent) -> Void)?
    private var batchPayload: (items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget)?
    private var nativeBatch: TelegramUploadBatchSubmission?
    var hasReceiver: Bool { single != nil || batch != nil }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
                caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        single = receive; awaitApproval(); return ApprovalDeadlineLease()
    }
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        batchPayload = (items, draft, target); batch = receive; awaitApproval(); return ApprovalDeadlineLease()
    }
    private func awaitApproval() {
        // Complete the provider handshake synchronously; a delayed test poll is
        // not part of the transport's pre-approval timeout budget.
        single?(.committing); single?(.awaitingApproval)
        batch?(.committing); batch?(.awaitingApproval)
    }
    func commit() { single?(.committing); batch?(.committing) }
    func accept(postbox: Postbox) {
        if let payload = batchPayload {
            // Complete the originally captured transport through the actual
            // native receipt transaction; Session intentionally cannot forge it.
            nativeBatch = TelegramUploadBatchSubmission(postbox: postbox, accountID: accountID,
                items: payload.items, draft: payload.draft, target: payload.target,
                enqueue: { receipt, messages in
                    telegramUploadBatchEnqueueLocally(postbox: postbox, receipt: receipt, messages: messages)
                }, receive: { [weak self] event in self?.batch?(event) })
        } else { single?(.accepted("approval-accepted")) }
    }
    func stop() { nativeBatch?.stop(); nativeBatch = nil }
}
@MainActor private final class ApprovalDeadlineLease: TelegramUploadLease { func stop() {} }

private nonisolated func approvalDeadlineSeed(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let peers = [1, 42].map { id in
            TelegramUser(id: PeerId(Int64(id)), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil,
                phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [],
                storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
                subscriberCount: nil, verificationIconFileId: nil)
        }
        transaction.updatePeersInternal(peers, update: { _, new in new })
        transaction.updatePeerCachedData(peerIds: Set([PeerId(42)])) { _, _ in CachedUserData() }
        transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(AppConfiguration.defaultValue))
        return true
    }
}
private nonisolated func approvalDeadlineQueued(_ box: Postbox, ids: [TelegramUploadQueueID]) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        ids.count == 1 && ids.allSatisfy { id in
            guard let message = transaction.getMessage(id.nativeID) else { return false }
            return message.id.peerId == PeerId(42) && message.id.namespace == Namespaces.Message.Local &&
                !message.flags.contains(.Incoming) && message.flags.contains(.Unsent)
        }
    }
}
