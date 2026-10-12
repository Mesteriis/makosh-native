import XCTest
import Foundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func extendedCaptionInput() throws -> TelegramComposerInput {
    try .init(formattedText: .init(text: "  **bold** 🦊 #тег  ", entities: [
        .init(offset: 11, length: 2, kind: .customEmoji(stickerPack: .name("Retained provenance"), fileID: 100))]))
}
private func extendedCaptionWire() throws -> [String: Any] {
    var wire = try pendingUploadSourceFactsJSON()
    wire["schemaVersion"] = 22; wire["resourceSchemaVersion"] = 19; wire["extendedCaption"] = true
    wire.removeValue(forKey: "originalDraft"); wire.removeValue(forKey: "replyTarget")
    wire["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(extendedCaptionInput()))
    wire["captionPolicy"] = ["maximumUTF16Count": 2048, "items": (wire["items"] as! [[String: Any]]).map {
        ["itemID": $0["id"]!, "fileCanHaveCaption": true]
    }]
    return wire
}
private func extendedCaptionDecode(_ wire: [String: Any]) throws -> TelegramPendingUploadDraft {
    try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: wire))
}
private func extendedCaptionFile(premium: Bool = false, custom: Bool = true) -> TelegramMediaFile {
    TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: 100), partialReference: nil,
        resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 100, accessHash: 53,
            size: 100, fileReference: Data([1, 2]), fileName: "synthetic.webp"),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/webp", size: 100,
        attributes: custom ? [.CustomEmoji(isPremium: premium, isSingleColor: false, alt: "🦊", packReference: nil)] : [],
        alternativeRepresentations: [])
}
private nonisolated func extendedCaptionUser(_ id: Int64, premium: Bool) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil,
        phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: premium ? [.isPremium] : [],
        emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func extendedCaptionSeed(_ box: Postbox, file: TelegramMediaFile, premium: Bool) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([extendedCaptionUser(1, premium: premium), extendedCaptionUser(42, premium: false)], update: { _, new in new })
        transaction.updatePeerCachedData(peerIds: Set([PeerId(42)])) { _, _ in CachedUserData() }
        transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(AppConfiguration.defaultValue))
        _ = transaction.updateMedia(file.fileId, update: file); transaction.storeMediaIfNotPresent(media: file)
        return true
    }
}
private nonisolated func extendedCaptionCached(_ box: Postbox, value: TelegramFormattedText, target: Int64 = 42) -> Signal<Bool, NoError> {
    box.transaction { transaction in telegramCustomEmojiCachedAdmission(formatted: value, transaction: transaction,
        accountID: 1, chatID: target) }
}

private nonisolated func extendedCaptionEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
    messages: [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { 100 }) { messages, admission, commit in
        let context = TelegramSendContext(accountID: 1, chatID: 42, threadID: nil,
            submissionRevision: receipt.draft.revision, messageCount: messages.count)
        return box.transaction { transaction in
            let file = transaction.getMedia(MediaId(namespace: Namespaces.Media.CloudFile, id: 100)) as? TelegramMediaFile
            return telegramNativeSendPreparation(transaction: transaction, context: context,
                messages: messages, files: file.map { [100: $0] } ?? [:], consent: nil)
        } |> mapToSignal { prepared in
            guard let prepared else { return .single([]) }
            return telegramNativePreparedEnqueue(preparation: prepared, authorization: .init(context: context, consent: nil),
                specificAdmission: admission, specificCommit: commit, enqueue: { messages, admission, commit in
                    enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false,
                        timestamp: 100, peerId: PeerId(42), messages: messages,
                        transactionAdmission: admission, transactionCommit: commit)
                }) |> map { $0 ?? [nil] }
        }
    }
}
private nonisolated func extendedCaptionMessages(_ box: Postbox, ids: [TelegramUploadQueueID]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0.nativeID) } }
}

final class TelegramUploadExtendedCaptionTests: XCTestCase {
    // Catches rewriting pack provenance or counting non-BMP source ranges after Markdown removal.
    func testExtendedProjectionPreservesCustomEmojiUnicodeRangesAndPackWithoutPromotingOlderRules() throws {
        let input = try extendedCaptionInput()
        let projected = try? TelegramUploadCaptionRules.extended.projection(input.formattedText)
        XCTAssertNotNil(projected)
        XCTAssertEqual(projected?.text, "bold 🦊 #тег")
        XCTAssertEqual(projected?.entities, [.init(offset: 0, length: 4, kind: .bold),
            .init(offset: 5, length: 2, kind: .customEmoji(stickerPack: .name("Retained provenance"), fileID: 100)),
            .init(offset: 8, length: 4, kind: .hashtag)])
        XCTAssertTrue(TelegramUploadCaptionRules.extended.canSend(input.formattedText, maximumUTF16Count: 2048))
        XCTAssertFalse(TelegramUploadCaptionRules.current.canSend(input.formattedText, maximumUTF16Count: 2048))
        XCTAssertThrowsError(try TelegramUploadCaptionRules.current.projection(input.formattedText))
        XCTAssertEqual(try TelegramUploadCaptionRules.legacy.projection(input.formattedText), input.formattedText)
    }
    // Catches silently interpreting an old encrypted pointer with the new outgoing policy.
    func testWire22RequiresExplicitPolicyAndPreservesQuoteThreadAndMarkerAfterCaptionRemoval() throws {
        var wire = try extendedCaptionWire()
        wire["threadID"] = 7
        let quote = try XCTUnwrap(TelegramReplyQuote(source: .init(text: "selected"), selection: .init(location: 0, length: 8)))
        let target = TelegramComposerReplyTarget(peerID: wire["chatID"] as! Int64,
            namespace: Namespaces.Message.Cloud, messageID: 3, threadID: 7, quote: quote)
        wire["replyTarget"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
        let draft = try XCTUnwrap(try? extendedCaptionDecode(wire))
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 22); XCTAssertEqual(draft.resourceSchemaVersion, 19)
        XCTAssertEqual(draft.captionRules, .extended); XCTAssertEqual(draft.threadID, 7); XCTAssertEqual(draft.replyTarget, target)
        let edited = draft.updating(captionInput: .empty, captionAboveMedia: false, mediaSpoiler: false, disposition: .prepared)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        XCTAssertEqual(saved["schemaVersion"] as? Int, 22); XCTAssertEqual(saved["resourceSchemaVersion"] as? Int, 19)
        XCTAssertEqual(saved["extendedCaption"] as? Bool, true); XCTAssertTrue(edited.isValid)
        XCTAssertEqual(try extendedCaptionDecode(saved), edited)
    }
    // Catches dropping the explicit marker, laundering future fields, or relaxing older wire semantics.
    func testNewMarkerCannotBeInjectedIntoOldWiresOrDowngradedToCurrentPolicy() throws {
        for version in [14, 15, 17, 19, 20, 21] {
            var wire = try extendedCaptionWire(); wire["schemaVersion"] = version
            if version < 20 { wire.removeValue(forKey: "resourceSchemaVersion") }
            if version == 21 { wire["threadID"] = 7 }
            XCTAssertFalse((try? extendedCaptionDecode(wire))?.isValid == true)
        }
        let base = try extendedCaptionWire()
        for change in 0..<6 {
            var wire = base
            switch change {
            case 0: wire.removeValue(forKey: "extendedCaption")
            case 1: wire["extendedCaption"] = false
            case 2: wire["extendedCaption"] = NSNull()
            case 3: wire.removeValue(forKey: "captionPolicy")
            case 4: wire["resourceSchemaVersion"] = 17
            default: wire["futureCaptionRecipe"] = true
            }
            XCTAssertFalse((try? extendedCaptionDecode(wire))?.isValid == true)
        }
    }
    // Catches Archive's independent plan retaining the global custom-emoji deny or silently promoting default callers.
    func testArchivePlanAllowsCustomEmojiOnlyWithExplicitExtendedRulesAndFrozenLimit() throws {
        let raw = try extendedCaptionInput().formattedText, policy = try TelegramUploadCaptionPolicy(maximumUTF16Count: 2048)
        let plan = try? TelegramUploadBatchPlan(archiveID: UUID(), caption: raw, captionPolicy: policy, captionRules: .extended)
        XCTAssertNotNil(plan); XCTAssertEqual(plan?.messages.count, 1)
        XCTAssertEqual(plan?.messages.first?.caption.text, "bold 🦊 #тег")
        XCTAssertEqual(plan?.messages.first?.caption.entities, [.init(offset: 0, length: 4, kind: .bold),
            .init(offset: 5, length: 2, kind: .customEmoji(stickerPack: .name("Retained provenance"), fileID: 100)),
            .init(offset: 8, length: 4, kind: .hashtag)])
        XCTAssertThrowsError(try TelegramUploadBatchPlan(archiveID: UUID(), caption: raw, captionPolicy: policy))
        XCTAssertFalse(telegramFormattedCaptionCanSend(raw))
        XCTAssertTrue(telegramFormattedCaptionCanSend(raw, allowCustomEmoji: true))
    }
}

@MainActor final class TelegramUploadExtendedCaptionIntegrationTests: TelegramSourceFactsIntegrationTestCase {
    private func waitReady(_ controller: TelegramUploadController) async throws {
        for _ in 0..<1000 where controller.phase == .preparing || controller.isRecoveryBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready); XCTAssertFalse(controller.isRecoveryBusy); XCTAssertNil(controller.recoveryStatus)
    }
    // Catches prepare/restore/Archive/append losing the marker, typed caption, immutable prefix or OFF file policy.
    func testNewPreparationArchiveAppendAndRestartRetainExtendedPolicyUnderBothStorageChoices() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let a = try await sourceFactsDocument(fixture, name: "a.txt", text: "a")
            let b = try await sourceFactsDocument(fixture, name: "b.txt", text: "b")
            let c = try await sourceFactsDocument(fixture, name: "c.txt", text: "c")
            defer { for item in [a, b, c] { try? item.discard() } }
            let store = fixture.session(box), id = UUID(), input = try extendedCaptionInput()
            try await store.prepare(preparationID: id, items: [a, b], isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: input, originalDraft: nil, captionPolicy: .init(maximumUTF16Count: 2048))
            let prepared = try await sourceFactsLoad(store)
            XCTAssertEqual(prepared.schemaVersion, 22); XCTAssertEqual(prepared.captionInput, input)
            guard prepared.schemaVersion == 22 else { continue }
            try await store.updatePresentation(preparationID: id, orderedIDs: [a.id, b.id], previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            let archived = try await sourceFactsLoad(store)
            XCTAssertEqual(archived.schemaVersion, 22); XCTAssertEqual(archived.captionPolicy, prepared.captionPolicy)
            let capture = try await store.captureAppend(snapshot: archived, additions: [c], target: fixture.target)
            let installed = try await store.installAppend(capture, target: fixture.target)
            XCTAssertEqual(installed.schemaVersion, 22); XCTAssertEqual(installed.captionInput, input)
            XCTAssertEqual(Array(installed.items.prefix(2)), prepared.items)
            XCTAssertEqual(installed.captionPolicy?.items.map(\.itemID), [a.id, b.id, c.id])
            let bundle = try await fixture.session(box).restoreBundle(draft: installed)
            defer { try? bundle.discard() }
            let controller = TelegramUploadController()
            controller.bind(provider: ExtendedCaptionProvider(), recoveryStore: store, requiresRecovery: true)
            defer { controller.clear() }
            XCTAssertTrue(controller.restore(draft: installed, bundle: bundle, target: fixture.target, restorationEpoch: controller.recoveryRestoreEpoch))
            XCTAssertTrue(controller.canSend); XCTAssertEqual(controller.captionMaximumUTF16Count, 2048)
            for record in installed.items.map(\.file) + [try XCTUnwrap(installed.archive?.file)] {
                let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                XCTAssertEqual(object != nil, enabled)
            }
        }
    }
    // Catches upgrading a restored old pointer merely by loading it, or refusing a new explicit native edit forever.
    func testExplicitCaptionEditVersionsCurrentPreparationThenKeepsNewPolicyAfterRemoval() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let source = fixture.root.appendingPathComponent("edit.txt"); try Data("edit".utf8).write(to: source)
        let store = fixture.session(box), controller = TelegramUploadController()
        controller.bind(provider: ExtendedCaptionProvider(), recoveryStore: store, requiresRecovery: true)
        defer { controller.clear() }
        controller.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false, target: fixture.target,
            captionInput: .empty, captionPolicy: try .init(maximumUTF16Count: 2048))
        try await waitReady(controller)
        let old = try await sourceFactsLoad(store); XCTAssertEqual(old.schemaVersion, 19)
        XCTAssertTrue(controller.updateCaptionInput(try extendedCaptionInput(), contextID: controller.captionContextID))
        for _ in 0..<100 { if try await sourceFactsLoad(store).schemaVersion == 22 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let edited = try await sourceFactsLoad(store)
        XCTAssertEqual(edited.schemaVersion, 22); XCTAssertEqual(edited.items, old.items); XCTAssertTrue(controller.canSend)
        guard edited.schemaVersion == 22 else { return }
        XCTAssertTrue(controller.updateCaptionInput(.empty, contextID: controller.captionContextID))
        for _ in 0..<100 { if try await sourceFactsLoad(store).captionInput == .empty { break }; try await Task.sleep(for: .milliseconds(10)) }
        let cleared = try await sourceFactsLoad(store); XCTAssertEqual(cleared.schemaVersion, 22)
    }
    // Catches a new wire passing UI/persistence while its receipt drops native custom media or skips a tier recheck.
    func testExtendedCaptionReachesNativeQueueAndAcceptedPointerWithExactAssociatedDocument() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let item = try await sourceFactsDocument(fixture, name: "native.txt", text: "native")
        defer { try? item.discard() }
        let store = fixture.session(box), id = UUID(), input = try extendedCaptionInput()
        try await store.prepare(preparationID: id, items: [item], isGrouped: false, presentation: .file,
            target: fixture.target, captionInput: input, originalDraft: nil, captionPolicy: .init(maximumUTF16Count: 2048))
        let initial = try await sourceFactsLoad(store)
        XCTAssertEqual(initial.schemaVersion, 22)
        guard initial.schemaVersion == 22 else { return }
        let file = extendedCaptionFile(premium: true)
        _ = try await sourceFactsValue(extendedCaptionSeed(box, file: file, premium: true))
        try await store.save(preparationID: id, chatID: 42, captionInput: input, disposition: .submissionStarted)
        let started = try await sourceFactsLoad(store)
        let result = expectation(description: "Native extended caption ACK")
        var ids: [TelegramUploadQueueID]?
        let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1,
            bundle: .init(items: [item], archive: nil), draft: started, target: fixture.target,
            enqueue: { receipt, messages in extendedCaptionEnqueue(box, receipt: receipt, messages: messages) },
            receive: { event in
                switch event {
                case let .accepted(value): ids = value; result.fulfill()
                case .rejected, .uncertain: XCTFail("Authentic extended caption must queue with native document"); result.fulfill()
                default: break
                }
            })
        defer { submission.stop() }
        await fulfillment(of: [result], timeout: 20)
        let messages = try await sourceFactsValue(extendedCaptionMessages(box, ids: ids ?? []))
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages.first?.text, "bold 🦊 #тег")
        XCTAssertEqual(messages.first?.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities,
            [.init(range: 0..<4, type: .Bold), .init(range: 5..<7, type: .CustomEmoji(stickerPack: .name("Retained provenance"), fileId: 100)),
             .init(range: 8..<12, type: .Hashtag)])
        XCTAssertTrue((messages.first?.associatedMedia[file.fileId] as? TelegramMediaFile)?.isEqual(to: file) == true)
        let accepted = try await sourceFactsLoad(store)
        XCTAssertEqual(accepted.schemaVersion, 22)
        guard case .acceptedBatch = accepted.disposition else { return XCTFail("Native ACK must retain new wire22 policy") }
    }
    // Catches trusting UI descriptors or a prior premium tier instead of current native cached authority.
    func testCachedAdmissionRequiresFullCustomDocumentAndCurrentTierWithSavedException() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let text = try extendedCaptionInput().formattedText
        _ = try await sourceFactsValue(extendedCaptionSeed(box, file: extendedCaptionFile(), premium: false))
        let free = try await sourceFactsValue(extendedCaptionCached(box, value: text)); XCTAssertTrue(free)
        _ = try await sourceFactsValue(extendedCaptionSeed(box, file: extendedCaptionFile(premium: true), premium: false))
        let denied = try await sourceFactsValue(extendedCaptionCached(box, value: text)); XCTAssertFalse(denied)
        let saved = try await sourceFactsValue(extendedCaptionCached(box, value: text, target: 1)); XCTAssertTrue(saved)
        _ = try await sourceFactsValue(extendedCaptionSeed(box, file: extendedCaptionFile(premium: true), premium: true))
        let premium = try await sourceFactsValue(extendedCaptionCached(box, value: text)); XCTAssertTrue(premium)
        _ = try await sourceFactsValue(extendedCaptionSeed(box, file: extendedCaptionFile(custom: false), premium: true))
        let ordinary = try await sourceFactsValue(extendedCaptionCached(box, value: text)); XCTAssertFalse(ordinary)
    }
}
@MainActor private final class ExtendedCaptionProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
        receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Prepare and restore never submit"); return ExtendedCaptionLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
        captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Prepare and restore never submit"); return ExtendedCaptionLease()
    }
}
@MainActor private final class ExtendedCaptionLease: TelegramUploadLease { func stop() {} }
