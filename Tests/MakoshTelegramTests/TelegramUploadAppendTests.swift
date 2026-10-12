import XCTest
import Foundation
import CoreGraphics
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func appendNativeUser(_ id: Int64) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: id == 1 ? [.isPremium] : [], emojiStatus: nil,
        usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
        profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func appendNativeSeed(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([appendNativeUser(1), appendNativeUser(42)], update: { _, new in new })
        transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(AppConfiguration.defaultValue))
        return true
    }
}
private nonisolated func appendNativeRead(_ box: Postbox, ids: [MessageId]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0) } }
}
private nonisolated func appendNativeEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
                                            messages: [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { 100 }) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(42), messages: messages, transactionAdmission: admission, transactionCommit: commit)
    }
}

private nonisolated func appendNativeSave(_ box: Postbox, draft: TelegramPendingUploadDraft, revision: UUID)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    box.transaction { transaction in
        telegramPendingUploadWrite(transaction: transaction, accountID: 1, draft: draft, expectedRevision: revision)
    }
}
private nonisolated func appendNativeInstall(_ box: Postbox, capture: TelegramUploadAppendCapture)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    box.transaction { transaction in telegramPendingUploadAppendWrite(transaction: transaction, accountID: 1, capture: capture) }
}

@MainActor final class TelegramUploadAppendTests: TelegramSourceFactsIntegrationTestCase {
    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func initial(_ fixture: SourceFactsTestArchive, store: TelegramPendingUploadSession,
                         items: [TelegramUploadBatchItem], current: Bool = true) async throws -> TelegramPendingUploadDraft {
        let id = UUID(), input = try TelegramComposerInput(formattedText: .init(text: " **append😀** "))
        if current {
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: input, originalDraft: nil, captionPolicy: .init(maximumUTF16Count: 2048))
        } else {
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: input, originalDraft: nil)
        }
        return try await sourceFactsLoad(store)
    }
    private func capture(_ store: TelegramPendingUploadSession, snapshot: TelegramPendingUploadDraft,
                         additions: [TelegramUploadBatchItem], target: TelegramUploadTarget) async -> TelegramUploadAppendCapture? {
        do { return try await store.captureAppend(snapshot: snapshot, additions: additions, target: target) }
        catch { XCTFail("Valid append must capture without replacing its predecessor: \(error)"); return nil }
    }
    private func submit(_ fixture: SourceFactsTestArchive, box: Postbox, draft: TelegramPendingUploadDraft,
                        bundle: TelegramRecoveredUploadBundle) async throws -> [Message] {
        let done = expectation(description: "Appended preparation native ACK")
        var ids: [TelegramUploadQueueID]?
        let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1, bundle: bundle, draft: draft,
            target: fixture.target, enqueue: { receipt, messages in appendNativeEnqueue(box, receipt: receipt, messages: messages) },
            receive: { event in
                switch event {
                case let .accepted(value): ids = value; done.fulfill()
                case .rejected: XCTFail("Authentic appended candidate must enqueue"); done.fulfill()
                case .uncertain: XCTFail("Local native admission must acknowledge deterministically"); done.fulfill()
                default: break
                }
            })
        defer { submission.stop() }
        await fulfillment(of: [done], timeout: 20)
        XCTAssertNotNil(ids)
        return try await sourceFactsValue(appendNativeRead(box, ids: (ids ?? []).map(\.nativeID)))
    }
    private func records(_ draft: TelegramPendingUploadDraft) -> [ArchiveFileRecord] {
        draft.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) + ($0.videoCover.map { [$0.file] } ?? []) }
            + (draft.archive.map { [$0.file] } ?? [])
    }

    // Catches replacing/re-uploading old resources, early pointer mutation, duplicate install copies or OFF→ON upload of local captures.
    func testCaptureThenAtomicInstallRetainsOldPrefixAndRetriesWithoutRecaptureUnderBothPolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let old = try await sourceFactsPhoto(fixture), new = try await sourceFactsDocument(fixture, name: "new.txt", text: "new payload")
            defer { try? old.discard(); try? new.discard() }
            let store = fixture.session(box), snapshot = try await initial(fixture, store: store, items: [old])
            guard let captured = await capture(store, snapshot: snapshot, additions: [new], target: fixture.target) else { continue }
            let unchanged = try await sourceFactsLoad(store)
            XCTAssertEqual(try bytes(unchanged), try bytes(snapshot)); XCTAssertNotEqual(captured.candidate.revision, snapshot.revision)
            XCTAssertEqual(try bytes(Array(captured.candidate.items.prefix(1))), try bytes(snapshot.items))
            XCTAssertEqual(captured.candidate.items.map(\.id), [old.id, new.id])
            XCTAssertEqual(captured.candidate.captionInput, snapshot.captionInput)
            XCTAssertEqual(captured.candidate.captionPolicy?.maximumUTF16Count, 2048)
            XCTAssertEqual(captured.candidate.captionPolicy?.items.map(\.itemID), [old.id, new.id])
            let localBefore = try fixture.localRecords()
            let installed = try await store.installAppend(captured, target: fixture.target)
            XCTAssertEqual(try bytes(installed), try bytes(captured.candidate))
            let retry = try await fixture.session(box).installAppend(captured, target: fixture.target)
            XCTAssertEqual(try bytes(retry), try bytes(installed)); XCTAssertEqual(try fixture.localRecords(), localBefore)
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("photo.jpg"))
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("new.txt"))
            let bundle = try await store.restoreBundle(draft: installed); defer { try? bundle.discard() }
            XCTAssertEqual(bundle.items.map(\.id), [old.id, new.id]); XCTAssertNotNil(bundle.items[0].originalFile)
            XCTAssertEqual(try Data(contentsOf: bundle.items[1].file.url), Data("new payload".utf8))
            if !enabled {
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let resumed = try await fixture.archive.resume(); XCTAssertEqual(resumed, 0)
            }
            for record in records(installed) {
                let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                XCTAssertEqual(object != nil, enabled)
            }
            let seeded = try await sourceFactsValue(appendNativeSeed(box)); XCTAssertTrue(seeded)
            try await store.save(preparationID: installed.id, chatID: installed.chatID,
                captionInput: installed.captionInput, disposition: .submissionStarted)
            let started = try await sourceFactsLoad(store)
            let messages = try await submit(fixture, box: box, draft: started, bundle: bundle)
            XCTAssertEqual(messages.count, 3); XCTAssertEqual(messages.first?.text, "append😀")
            XCTAssertEqual(messages.first?.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities,
                [MessageTextEntity(range: 0..<8, type: .Bold)])
            let accepted = try await sourceFactsLoad(store)
            XCTAssertEqual(accepted.items.map(\.id), [old.id, new.id]); XCTAssertEqual(accepted.captionPolicy, installed.captionPolicy)
            guard case .acceptedBatch = accepted.disposition else { XCTFail("Whole appended tuple needs durable native ACK"); continue }
        }
    }

    // Catches a capture/install race overwriting newer caption, placement or list changes from a second Session.
    func testStaleWholeSnapshotFailsBeforeCaptureAndAfterCaptureWithoutOverwritingNewerEdits() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let old = try await sourceFactsDocument(fixture, name: "old.txt", text: "old"), new = try await sourceFactsDocument(fixture, name: "new.txt", text: "new")
        defer { try? old.discard(); try? new.discard() }
        let store = fixture.session(box), snapshot = try await initial(fixture, store: store, items: [old])
        guard let captured = await capture(store, snapshot: snapshot, additions: [new], target: fixture.target) else { return }
        let latestInput = try TelegramComposerInput(formattedText: .init(text: "newer caption"))
        try await fixture.session(box).save(preparationID: snapshot.id, chatID: 42, captionInput: latestInput, disposition: .prepared)
        let latest = try await sourceFactsLoad(store), localBefore = try fixture.localRecords()
        do { _ = try await store.installAppend(captured, target: fixture.target); XCTFail("Stale append cannot overwrite newer edits") } catch { }
        do { _ = try await store.captureAppend(snapshot: snapshot, additions: [new], target: fixture.target); XCTFail("Stale snapshot cannot capture new copies") } catch { }
        let after = try await sourceFactsLoad(store)
        XCTAssertEqual(try bytes(after), try bytes(latest)); XCTAssertEqual(try fixture.localRecords(), localBefore)
        // Same UUID revision with a different opaque spelling must still fail the full snapshot comparison.
        let forged = try TelegramPendingUploadDraft(id: latest.id, revision: latest.revision, accountID: latest.accountID,
            chatID: latest.chatID, title: latest.title, captionInput: snapshot.captionInput, originalDraft: nil,
            replyTarget: nil, items: latest.items, isGrouped: latest.isGrouped, presentation: latest.presentation,
            captionRules: latest.captionRules, mediaRules: latest.mediaRules, archive: latest.archive, captionPolicy: latest.captionPolicy)
        do { _ = try await store.captureAppend(snapshot: forged, additions: [new], target: fixture.target); XCTFail("Wrong full snapshot cannot capture") } catch { }
    }

    // Catches UUID reuse between Session's precheck and the native CAS, including a false lost-ACK candidate match.
    func testNativeWholeSnapshotGuardRejectsReusedPredecessorAndCandidateRevision() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let old = try await sourceFactsDocument(fixture, name: "old.txt", text: "old"), new = try await sourceFactsDocument(fixture, name: "new.txt", text: "new")
        defer { try? old.discard(); try? new.discard() }
        let store = fixture.session(box), snapshot = try await initial(fixture, store: store, items: [old])
        guard let captured = await capture(store, snapshot: snapshot, additions: [new], target: fixture.target) else { return }
        let changedInput = try TelegramComposerInput(formattedText: .init(text: "later edit"))
        for revision in [snapshot.revision, captured.candidate.revision] {
            let current = try await sourceFactsLoad(store)
            let intermediate = current.updating(captionInput: changedInput, captionAboveMedia: current.captionAboveMedia,
                mediaSpoiler: current.mediaSpoiler, disposition: .prepared)
            let first = try await sourceFactsValue(appendNativeSave(box, draft: intermediate, revision: current.revision)); try first.get()
            let reused = try TelegramPendingUploadDraft(id: snapshot.id, revision: revision, accountID: 1, chatID: 42,
                title: snapshot.title, captionInput: changedInput, originalDraft: snapshot.originalDraft,
                replyTarget: snapshot.replyTarget, items: snapshot.items, isGrouped: snapshot.isGrouped,
                presentation: snapshot.presentation, captionRules: snapshot.captionRules, mediaRules: snapshot.mediaRules,
                archive: snapshot.archive, captionPolicy: snapshot.captionPolicy)
            let second = try await sourceFactsValue(appendNativeSave(box, draft: reused, revision: intermediate.revision)); try second.get()
            let admission = try await sourceFactsValue(appendNativeInstall(box, capture: captured))
            guard case .failure(.conflict) = admission else { XCTFail("Native append must compare full bytes despite reused UUID"); continue }
            let after = try await sourceFactsLoad(store); XCTAssertEqual(try bytes(after), try bytes(reused))
        }
    }

    // Catches exposing a partial append when a later file is corrupt, duplicated, missing or has inconsistent source facts.
    func testInvalidLaterAdditionAndDuplicateIDLeaveOldPreparationAndCopiesUntouched() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let old = try await sourceFactsDocument(fixture, name: "old.txt", text: "old"), good = try await sourceFactsDocument(fixture, name: "good.txt", text: "good"), bad = try await sourceFactsDocument(fixture, name: "bad.txt", text: "bad")
        defer { try? old.discard(); try? good.discard(); try? bad.discard() }
        let store = fixture.session(box), snapshot = try await initial(fixture, store: store, items: [old])
        let before = try fixture.localRecords()
        try Data("tampered".utf8).write(to: bad.file.url)
        do { _ = try await store.captureAppend(snapshot: snapshot, additions: [good, bad], target: fixture.target); XCTFail("Whole append must validate before first capture") } catch { }
        do { _ = try await store.captureAppend(snapshot: snapshot, additions: [old], target: fixture.target); XCTFail("Duplicate old ID cannot append") } catch { }
        let after = try await sourceFactsLoad(store)
        XCTAssertEqual(try bytes(after), try bytes(snapshot)); XCTAssertEqual(try fixture.localRecords(), before)
    }

    // Catches stale ZIP members, losing legacy recipe/schema or saving a new ZIP to S3 when the chat flag is OFF.
    func testActiveArchiveRebuildsOldPlusNewBeforeSingleCASAndKeepsLegacyOrCurrentRecipe() async throws {
        for current in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let a = try await sourceFactsDocument(fixture, name: "a.txt", text: "a"), b = try await sourceFactsDocument(fixture, name: "b.txt", text: "b"), c = try await sourceFactsDocument(fixture, name: "c.txt", text: "c")
            defer { try? a.discard(); try? b.discard(); try? c.discard() }
            let store = fixture.session(box), start = try await initial(fixture, store: store, items: [a, b], current: current)
            try await store.updatePresentation(preparationID: start.id, orderedIDs: [a.id, b.id], previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            let snapshot = try await sourceFactsLoad(store)
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("a.txt"))
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("b.txt"))
            guard let captured = await capture(store, snapshot: snapshot, additions: [c], target: fixture.target) else { continue }
            let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(try bytes(unchanged), try bytes(snapshot))
            let candidate = captured.candidate
            XCTAssertEqual(candidate.presentation, .archive); XCTAssertEqual(candidate.schemaVersion, current ? 19 : 18)
            XCTAssertEqual(candidate.captionRules, current ? .current : .reference)
            XCTAssertEqual(try bytes(Array(candidate.items.prefix(2))), try bytes(snapshot.items))
            XCTAssertNotEqual(candidate.archive?.id, snapshot.archive?.id)
            XCTAssertEqual(candidate.archive?.members.map(\.itemID), [a.id, b.id, c.id])
            let saved = try await store.installAppend(captured, target: fixture.target)
            let bundle = try await store.restoreBundle(draft: saved); defer { try? bundle.discard() }
            XCTAssertEqual(bundle.archive?.members.map(\.sourceName), ["a.txt", "b.txt", "c.txt"])
            XCTAssertEqual(bundle.items.map(\.id), [a.id, b.id, c.id])
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
            let resumed = try await fixture.archive.resume(); XCTAssertEqual(resumed, 0)
            for record in records(saved) {
                let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey); XCTAssertNil(object)
            }
        }
    }

    // Catches reusing an inactive cached archive after appending to File, or promoting an older caption projection.
    func testAppendingToFileInvalidatesCachedZIPAndPreservesLegacy17AndCurrent19() async throws {
        for current in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let a = try await sourceFactsDocument(fixture, name: "a.txt", text: "a"), b = try await sourceFactsDocument(fixture, name: "b.txt", text: "b"), c = try await sourceFactsDocument(fixture, name: "c.txt", text: "c")
            defer { try? a.discard(); try? b.discard(); try? c.discard() }
            let store = fixture.session(box), start = try await initial(fixture, store: store, items: [a, b], current: current)
            try await store.updatePresentation(preparationID: start.id, orderedIDs: [a.id, b.id], previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            try await store.updatePresentation(preparationID: start.id, orderedIDs: [a.id, b.id], previousPresentation: .archive,
                previousGrouping: false, presentation: .file, isGrouped: false, target: fixture.target)
            let snapshot = try await sourceFactsLoad(store); XCTAssertNotNil(snapshot.archive)
            guard let captured = await capture(store, snapshot: snapshot, additions: [c], target: fixture.target) else { continue }
            XCTAssertNil(captured.candidate.archive); XCTAssertEqual(captured.candidate.schemaVersion, current ? 19 : 17)
            let saved = try await store.installAppend(captured, target: fixture.target)
            XCTAssertEqual(saved.captionRules, current ? .current : .reference)
            let projected = try saved.captionRules.projection(saved.captionInput.formattedText)
            XCTAssertEqual(projected.text, current ? "append😀" : "**append😀**")
        }
    }
    // Catches changing the current Media selection or retaining collage after an incompatible document drop.
    func testAppendRetainsMediaAndDisablesGroupingForMixedSelectionWithFrozenCaptionOptions() async throws {
        for appendDocument in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let old = try await sourceFactsPhoto(fixture, name: "old.jpg")
            let addition = try await (appendDocument ? sourceFactsDocument(fixture, name: "new.txt", text: "new") : sourceFactsPhoto(fixture, name: "new.jpg"))
            defer { try? old.discard(); try? addition.discard() }
            let store = fixture.session(box), id = UUID(), input = try TelegramComposerInput(formattedText: .init(text: " **media** "))
            try await store.prepare(preparationID: id, items: [old], isGrouped: true, presentation: .media,
                target: fixture.target, captionInput: input, captionAboveMedia: true, mediaSpoiler: true,
                originalDraft: nil, captionPolicy: .init(maximumUTF16Count: 2048))
            let snapshot = try await sourceFactsLoad(store)
            guard let captured = await capture(store, snapshot: snapshot, additions: [addition], target: fixture.target) else { continue }
            XCTAssertEqual(captured.candidate.presentation, .media)
            XCTAssertEqual(captured.candidate.isGrouped, !appendDocument)
            XCTAssertEqual(captured.candidate.captionInput, input); XCTAssertTrue(captured.candidate.captionAboveMedia)
            XCTAssertTrue(captured.candidate.mediaSpoiler)
            XCTAssertEqual(try bytes(Array(captured.candidate.items.prefix(1))), try bytes(snapshot.items))
            XCTAssertEqual(captured.candidate.captionPolicy?.items.first, snapshot.captionPolicy?.items.first)
            let installed = try await store.installAppend(captured, target: fixture.target)
            let bundle = try await store.restoreBundle(draft: installed); defer { try? bundle.discard() }
            XCTAssertEqual(bundle.items[0].file.mode, .photo); XCTAssertNotNil(bundle.items[0].originalFile)
            if appendDocument {
                let file = try XCTUnwrap(bundle.items[0].presented(as: .file))
                XCTAssertEqual(try Data(contentsOf: file.file.url), try Data(contentsOf: XCTUnwrap(bundle.items[0].originalFile).url))
            }
        }
    }

    // Catches accepting a syntactically valid frozen policy that disagrees with the authenticated final File payload.
    func testCaptureRefusesFrozenCaptionCapabilityMismatchBeforeCandidatePublication() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let old = try await sourceFactsDocument(fixture, name: "old.txt", text: "old"), new = try await sourceFactsDocument(fixture, name: "new.txt", text: "new")
        defer { try? old.discard(); try? new.discard() }
        let store = fixture.session(box), initial = try await initial(fixture, store: store, items: [old])
        let policyBytes = try bytes(XCTUnwrap(initial.captionPolicy))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: policyBytes) as? [String: Any])
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        items[0]["fileCanHaveCaption"] = false; object["items"] = items
        let wrongPolicy = try JSONDecoder().decode(TelegramUploadCaptionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
        let snapshot = try TelegramPendingUploadDraft(id: initial.id, accountID: initial.accountID, chatID: initial.chatID,
            title: initial.title, captionInput: initial.captionInput, originalDraft: initial.originalDraft,
            replyTarget: initial.replyTarget, items: initial.items, isGrouped: initial.isGrouped, presentation: initial.presentation,
            captionRules: initial.captionRules, mediaRules: initial.mediaRules, captionPolicy: wrongPolicy)
        XCTAssertTrue(snapshot.isValid)
        let saved = try await sourceFactsValue(appendNativeSave(box, draft: snapshot, revision: initial.revision)); try saved.get()
        do { _ = try await store.captureAppend(snapshot: snapshot, additions: [new], target: fixture.target); XCTFail("Capture must authenticate frozen caption capabilities") } catch { }
        let after = try await sourceFactsLoad(store); XCTAssertEqual(try bytes(after), try bytes(snapshot))
    }

    // Catches cancellation before admission triggering new captures or changing the predecessor pointer.
    func testPreCancelledCaptureAndInstallPreserveRecoverablePredecessor() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let old = try await sourceFactsDocument(fixture, name: "old.txt", text: "old"), new = try await sourceFactsDocument(fixture, name: "new.txt", text: "new")
        defer { try? old.discard(); try? new.discard() }
        let store = fixture.session(box), snapshot = try await initial(fixture, store: store, items: [old])
        let before = try fixture.localRecords()
        let cancelledCapture = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.captureAppend(snapshot: snapshot, additions: [new], target: fixture.target)
        }
        do { _ = try await cancelledCapture.value; XCTFail("Cancelled capture must not write") } catch is CancellationError { }
        XCTAssertEqual(try fixture.localRecords(), before)
        guard let captured = await capture(store, snapshot: snapshot, additions: [new], target: fixture.target) else { return }
        let cancelledInstall = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.installAppend(captured, target: fixture.target)
        }
        do { _ = try await cancelledInstall.value; XCTFail("Cancelled install must not replace the pointer") } catch is CancellationError { }
        let after = try await sourceFactsLoad(store); XCTAssertEqual(try bytes(after), try bytes(snapshot))
    }

    // Catches dropping or reassigning a video's separately owned cover when capturing a new append item.
    func testAppendingVideoPreservesItsNativeMetadataAndSeparateCoverAfterRestore() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let old = try await sourceFactsDocument(fixture, name: "old.txt", text: "old")
        defer { try? old.discard() }
        let source = fixture.root.appendingPathComponent("clip.mp4"), coverSource = fixture.root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(source); try writeUploadVideoCoverFixture(coverSource)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(coverSource, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        let file = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .video,
            pixelWidth: raw.pixelWidth, pixelHeight: raw.pixelHeight, url: raw.url, directory: raw.directory,
            video: raw.video, videoCover: cover)
        let facts = try await TelegramUploadSourceFactsIO.inspect(itemID: file.id,
            raw: TelegramUploadBatchItem(id: file.id, file: file).rawSource, role: .prepared)
        let addition = TelegramUploadBatchItem(id: file.id, file: file, sourceFacts: facts)
        defer { try? addition.discard() }
        let store = fixture.session(box), snapshot = try await initial(fixture, store: store, items: [old])
        guard let captured = await capture(store, snapshot: snapshot, additions: [addition], target: fixture.target) else { return }
        let saved = try await store.installAppend(captured, target: fixture.target)
        XCTAssertEqual(saved.items.last?.video, raw.video); XCTAssertEqual(saved.items.last?.videoCover?.file.plaintextSHA256, cover.sha256)
        let bundle = try await store.restoreBundle(draft: saved); defer { try? bundle.discard() }
        XCTAssertEqual(bundle.items.last?.file.video, raw.video)
        XCTAssertEqual(bundle.items.last?.file.videoCover?.sha256, cover.sha256)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(bundle.items.last?.file.videoCover).url), try Data(contentsOf: cover.url))
    }

    // Catches a real S3 capture failure clearing or replacing the already durable preparation.
    func testStorageFailureRetainsOldPointerAndOriginalResource() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let old = try await sourceFactsDocument(fixture, name: "old.txt", text: "old"), addition = try await sourceFactsDocument(fixture, name: "new.txt", text: "new")
        defer { try? old.discard(); try? addition.discard() }
        let store = fixture.session(box), snapshot = try await initial(fixture, store: store, items: [old])
        try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
        let config = fixture.configuration
        let refused = try S3ObjectStoreConfiguration(endpoint: "http://127.0.0.1:1", region: config.region,
            bucket: config.bucket, accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey)
        let unavailable = try ArchiveFileRepository(connectionString: fixture.database.connectionString, schema: fixture.database.schema,
            configuration: refused, spoolDirectory: fixture.root.appendingPathComponent("refused-queue"),
            keyProvider: { _, _ in Data(repeating: 0x59, count: 32) })
        let failing = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
            files: { TelegramPendingUploadFiles(repository: unavailable) })
        do { _ = try await failing.captureAppend(snapshot: snapshot, additions: [addition], target: fixture.target); XCTFail("Refused S3 must fail append capture") } catch { }
        let after = try await sourceFactsLoad(store); XCTAssertEqual(try bytes(after), try bytes(snapshot))
        let restored = try await store.restoreItems(draft: after); defer { restored.forEach { try? $0.discard() } }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.first).file.url), Data("old".utf8))
    }

}
