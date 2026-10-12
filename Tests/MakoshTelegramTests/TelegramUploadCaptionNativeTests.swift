import XCTest
import Foundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func captionNativeUser(_ id: Int64, premium: Bool) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: premium ? [.isPremium] : [], emojiStatus: nil,
        usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
        profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func captionNativeSeed(_ box: Postbox, premium: Bool, maximum: Int? = nil) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([captionNativeUser(1, premium: premium), captionNativeUser(42, premium: false)], update: { _, new in new })
        var config = AppConfiguration.defaultValue
        config.data = maximum.map { .dictionary(["caption_length_limit_premium": .number(Double($0))]) }
        transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(config))
        return true
    }
}
private nonisolated func captionNativeRead(_ box: Postbox, ids: [MessageId]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0) } }
}
private nonisolated func captionNativeEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
                                             messages: [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { 100 }) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(42), messages: messages, transactionAdmission: admission, transactionCommit: commit)
    }
}

@MainActor final class TelegramUploadCaptionNativeTests: TelegramSourceFactsIntegrationTestCase {
    private func prepare(_ store: TelegramPendingUploadSession, fixture: SourceFactsTestArchive, id: UUID,
                         items: [TelegramUploadBatchItem], input: TelegramComposerInput) async -> Bool {
        do {
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: input, originalDraft: nil,
                captionPolicy: .init(maximumUTF16Count: 2048))
            return true
        } catch { XCTFail("Explicit account caption policy must durably prepare: \(error)"); return false }
    }
    private func submit(_ fixture: SourceFactsTestArchive, box: Postbox, draft: TelegramPendingUploadDraft,
                        items: [TelegramUploadBatchItem], archive: TelegramUploadArchiveIO.Archive? = nil, shouldAccept: Bool) async throws -> [Message] {
        let done = expectation(description: "Caption admission result")
        var ids: [TelegramUploadQueueID]?
        let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1, bundle: .init(items: items, archive: archive), draft: draft,
            target: fixture.target, enqueue: { receipt, messages in captionNativeEnqueue(box, receipt: receipt, messages: messages) },
            receive: { event in
                switch event {
                case let .accepted(value): ids = value; XCTAssertTrue(shouldAccept); done.fulfill()
                case .rejected: XCTAssertFalse(shouldAccept); done.fulfill()
                case .uncertain: XCTFail("Deterministic account admission must not become uncertain"); done.fulfill()
                default: break
                }
            })
        defer { submission.stop() }
        await fulfillment(of: [done], timeout: 20)
        if shouldAccept { XCTAssertNotNil(ids) } else { XCTAssertNil(ids) }
        return try await sourceFactsValue(captionNativeRead(box, ids: (ids ?? []).map(\.nativeID)))
    }

    // Catches a premium limit stopping at UI/persistence instead of reaching final native message attributes and complete ACK.
    func testPremiumPolicyRestoresAndQueuesProjectedCaptionUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let item = try await sourceFactsDocument(fixture, name: "caption.txt", text: "Synthetic payload")
            defer { try? item.discard() }
            let store = fixture.session(box), id = UUID()
            let body = String(repeating: "я", count: 1500)
            let input = try TelegramComposerInput(formattedText: .init(text: " **\(body)** "))
            guard await prepare(store, fixture: fixture, id: id, items: [item], input: input) else { continue }
            let frozen = try await sourceFactsLoad(store)
            XCTAssertEqual(frozen.schemaVersion, 19); XCTAssertEqual(frozen.captionRules, .current)
            XCTAssertEqual(frozen.captionPolicy?.maximumUTF16Count, 2048); XCTAssertEqual(frozen.captionInput, input)
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("caption.txt"))
            let restored = try await fixture.session(box).restoreItems(draft: frozen)
            defer { restored.forEach { try? $0.discard() } }
            try await store.save(preparationID: id, chatID: 42, captionInput: input, disposition: .submissionStarted)
            let started = try await sourceFactsLoad(store)
            let seeded = try await sourceFactsValue(captionNativeSeed(box, premium: true)); XCTAssertTrue(seeded)
            let messages = try await submit(fixture, box: box, draft: started, items: restored, shouldAccept: true)
            XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages.first?.text, body)
            let entities = messages.first?.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities
            XCTAssertEqual(entities, [MessageTextEntity(range: 0..<1500, type: .Bold)])
            let saved = try await sourceFactsLoad(store)
            XCTAssertEqual(saved.captionPolicy, frozen.captionPolicy)
            guard case .acceptedBatch = saved.disposition else { XCTFail("Native ACK must durably retain schema19 policy"); continue }
            let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: frozen.file.objectKey)
            XCTAssertEqual(object != nil, enabled)
        }
    }

    // Catches freezing a premium entitlement forever: a lower current tier/config must reject before queue insertion.
    func testAccountDowngradeAndConfigurationShrinkRejectWithoutTruncation() async throws {
        for maximum in [Int?.none, 1200] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let item = try await sourceFactsDocument(fixture, name: "tier.txt", text: "Synthetic payload")
            defer { try? item.discard() }
            let store = fixture.session(box), id = UUID()
            let input = try TelegramComposerInput(formattedText: .init(text: String(repeating: "x", count: 1500)))
            guard await prepare(store, fixture: fixture, id: id, items: [item], input: input) else { continue }
            try await store.save(preparationID: id, chatID: 42, captionInput: input, disposition: .submissionStarted)
            let draft = try await sourceFactsLoad(store)
            let seeded = try await sourceFactsValue(captionNativeSeed(box, premium: maximum != nil, maximum: maximum)); XCTAssertTrue(seeded)
            let messages = try await submit(fixture, box: box, draft: draft, items: [item], shouldAccept: false)
            XCTAssertTrue(messages.isEmpty)
            let after = try await sourceFactsLoad(store)
            XCTAssertEqual(after.captionInput, input); XCTAssertEqual(after.disposition, .submissionStarted)
        }
    }

    // Catches a mode/archive/reorder constructor dropping the frozen policy or attaching capabilities to the wrong ordered item.
    func testPolicySurvivesArchiveModeReorderRemovalAndRetryWithoutPromotion() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = try await [sourceFactsDocument(fixture, name: "a.txt", text: "a"),
            sourceFactsDocument(fixture, name: "b.txt", text: "b")]
        defer { items.forEach { try? $0.discard() } }
        let store = fixture.session(box), id = UUID(), input = try TelegramComposerInput(formattedText: .init(text: "**caption**"))
        guard await prepare(store, fixture: fixture, id: id, items: items, input: input) else { return }
        let initial = try await sourceFactsLoad(store), ids = items.map(\.id)
        try await store.updatePresentation(preparationID: id, orderedIDs: ids, previousPresentation: .file,
            previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
        let archive = try await sourceFactsLoad(store)
        XCTAssertEqual(archive.schemaVersion, 19); XCTAssertEqual(archive.captionPolicy, initial.captionPolicy)
        XCTAssertNotNil(archive.archive)
        let bundle = try await store.restoreBundle(draft: archive); defer { try? bundle.discard() }
        XCTAssertNotNil(bundle.archive)
        try await store.updatePresentation(preparationID: id, orderedIDs: ids, previousPresentation: .archive,
            previousGrouping: false, presentation: .file, isGrouped: false, target: fixture.target)
        try await store.updateItems(preparationID: id, previousIDs: ids, previousGrouping: false,
            previousPresentation: .file, orderedIDs: ids.reversed(), isGrouped: false, presentation: .file, target: fixture.target)
        let reordered = try await sourceFactsLoad(store)
        XCTAssertEqual(reordered.captionPolicy?.items.map(\.itemID), Array(ids.reversed())); XCTAssertNil(reordered.archive)
        try await store.updateItems(preparationID: id, previousIDs: Array(ids.reversed()), previousGrouping: false,
            previousPresentation: .file, orderedIDs: [ids[0]], isGrouped: false, presentation: .file, target: fixture.target)
        let reduced = try await sourceFactsLoad(store)
        XCTAssertEqual(reduced.schemaVersion, 19); XCTAssertEqual(reduced.captionPolicy?.maximumUTF16Count, 2048)
        XCTAssertEqual(reduced.captionPolicy?.items.map(\.itemID), [ids[0]])
        do {
            try await store.prepare(preparationID: id, items: [items[0]], isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: input, originalDraft: nil)
            XCTFail("A nil policy retry cannot downgrade a versioned preparation")
        } catch { }
    }
    // Catches an observer that guesses a missing account, samples only once, or misses config/tier changes.
    func testAccountLimitObserverWaitsForOwnUserAndTracksTierAndConfiguration() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        var values: [Int] = []
        let limits = (telegramUploadCaptionLimit(postbox: box, accountID: 1) |> deliverOnMainQueue).start(next: { values.append($0) })
        defer { limits.dispose() }
        try await Task.sleep(for: .milliseconds(30)); XCTAssertTrue(values.isEmpty)
        for (premium, maximum, expected) in [(false, Int?.none, 1024), (true, nil, 2048), (true, 3000, 3000), (false, nil, 1024)] {
            let seeded = try await sourceFactsValue(captionNativeSeed(box, premium: premium, maximum: maximum)); XCTAssertTrue(seeded)
            for _ in 0..<50 where values.last != expected { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(values.last, expected)
        }
        XCTAssertEqual(values, [1024, 2048, 3000, 1024])
    }

    // Catches the ZIP validation path keeping the old1024 projection while the ordinary schema19 path accepts premium captions.
    func testSchema19ArchiveQueuesPremiumProjectionAfterRestore() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = try await [sourceFactsDocument(fixture, name: "zip-a.txt", text: "a"), sourceFactsDocument(fixture, name: "zip-b.txt", text: "b")]
        defer { items.forEach { try? $0.discard() } }
        let store = fixture.session(box), id = UUID(), body = String(repeating: "x", count: 1500)
        let input = try TelegramComposerInput(formattedText: .init(text: "**\(body)**"))
        guard await prepare(store, fixture: fixture, id: id, items: items, input: input) else { return }
        try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
            previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
        let frozen = try await sourceFactsLoad(store), bundle = try await store.restoreBundle(draft: frozen)
        defer { try? bundle.discard() }
        try await store.save(preparationID: id, chatID: 42, captionInput: input, disposition: .submissionStarted)
        let draft = try await sourceFactsLoad(store)
        let seeded = try await sourceFactsValue(captionNativeSeed(box, premium: true)); XCTAssertTrue(seeded)
        let messages = try await submit(fixture, box: box, draft: draft, items: bundle.items, archive: bundle.archive, shouldAccept: true)
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages.first?.text, body)
        XCTAssertEqual((messages.first?.media.first as? TelegramMediaFile)?.mimeType, "application/zip")
        let accepted = try await sourceFactsLoad(store); XCTAssertEqual(accepted.captionPolicy, frozen.captionPolicy)
    }

    // Catches classifying caption/comment from the picker MIME instead of the final native typed payload.
    func testTypedOggGIFAndWebPCaptionCapabilitiesSurviveRestoreAndReachNativeCardinality() async throws {
        for kind in ["ogg", "mp3", "gif", "webp"] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let source = fixture.root.appendingPathComponent("typed.webp")
            switch kind {
            case "ogg": try uploadOpusAudioFixture().write(to: source)
            case "mp3": try writeUploadMP3AudioFixture(source)
            case "gif": try uploadGIFTimingFixture.write(to: source)
            default: try writeUploadWebPFixture(source)
            }
            let controller = TelegramUploadController(); controller.bind(provider: CaptionPickerProvider())
            controller.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false,
                target: fixture.target, captionInput: .empty)
            for _ in 0..<1000 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(controller.phase, .ready)
            let item = try XCTUnwrap(controller.items.first)
            controller.discard = { _ in }; controller.clear()
            defer { try? item.discard() }
            let store = fixture.session(box), id = UUID(), captionable = kind == "ogg" || kind == "gif"
            let input = try TelegramComposerInput(formattedText: .init(text: " **caption😀** "))
            guard await prepare(store, fixture: fixture, id: id, items: [item], input: input) else { continue }
            let frozen = try await sourceFactsLoad(store), policy = try XCTUnwrap(frozen.captionPolicy)
            XCTAssertEqual(policy.items.first?.fileCanHaveCaption, captionable)
            XCTAssertEqual(TelegramUploadCaptionRules.usesCaptionPlaceholder(items: [item], presentation: .file,
                isGrouped: false, captionPolicy: policy), captionable)
            let projected = try XCTUnwrap(item.presented(as: .file))
            let old = try TelegramUploadBatchPlan(items: [projected], isGrouped: false, caption: input.formattedText,
                presentation: .file, captionRules: .reference)
            XCTAssertEqual(old.messages.count, 2, "Old selection-MIME/WebP rules keep their frozen leading comment")
            try FileManager.default.removeItem(at: source)
            let restored = try await store.restoreItems(draft: frozen); defer { restored.forEach { try? $0.discard() } }
            try await store.save(preparationID: id, chatID: 42, captionInput: input, disposition: .submissionStarted)
            let draft = try await sourceFactsLoad(store)
            let seeded = try await sourceFactsValue(captionNativeSeed(box, premium: false)); XCTAssertTrue(seeded)
            let messages = try await submit(fixture, box: box, draft: draft, items: restored, shouldAccept: true)
            XCTAssertEqual(messages.count, captionable ? 1 : 2)
            XCTAssertEqual(messages.first?.text, "caption😀")
            let document = try XCTUnwrap(messages.last?.media.first as? TelegramMediaFile)
            XCTAssertEqual(document.mimeType, kind == "ogg" ? "audio/ogg" : kind == "gif" ? "image/gif" : "image/webp")
            XCTAssertEqual(document.isVoice, false)
            XCTAssertEqual(document.isStaticSticker, kind == "webp")
            let accepted = try await sourceFactsLoad(store); XCTAssertEqual(accepted.captionPolicy, policy)
        }
    }

}

@MainActor private final class CaptionPickerProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Picker preparation cannot submit"); return CaptionPickerLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Picker preparation cannot submit"); return CaptionPickerLease()
    }
}
@MainActor private final class CaptionPickerLease: TelegramUploadLease { func stop() {} }
