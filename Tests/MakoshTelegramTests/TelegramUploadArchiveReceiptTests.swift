import XCTest
import Foundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramUploadArchiveReceiptTests: TelegramSourceFactsIntegrationTestCase {
    // Catches the provider expanding a retained bundle into originals or recapturing it in S3.
    func testWholeBundleSubmissionQueuesOneZIPWithoutNewArchiveCopies() async throws {
        for enabled in [false, true] {
            let setup = try await prepared(enabled: enabled, includePhoto: enabled, accountID: -1)
            defer { try? setup.bundle.discard() }
            let terminal = expectation(description: "Whole bundle native admission")
            var events: [TelegramUploadBatchEvent] = []
            let provider: any TelegramUploadBatchProvider = TelegramSyntheticUploadProvider(postbox: setup.box, loseAcknowledgement: !enabled)
            let lease = provider.submit(bundle: setup.bundle, draft: setup.draft, target: setup.fixture.target, receive: { event in
                    events.append(event)
                    switch event { case .accepted, .uncertain, .rejected: terminal.fulfill(); default: break }
                })
            defer { lease.stop() }
            await fulfillment(of: [terminal], timeout: 20)
            XCTAssertEqual(events.first, .committing)
            if enabled {
                guard case let .accepted(ids) = events.last, ids.count == 1 else {
                    XCTFail("Provider must acknowledge one native ZIP"); continue
                }
            } else { XCTAssertEqual(events.last, .uncertain) }
            let accepted = try await sourceFactsLoad(setup.fixture.session(setup.box))
            guard case let .acceptedBatch(ids) = accepted.disposition, ids.count == 1 else {
                XCTFail("Lost ACK must retain the complete one-ZIP receipt"); continue
            }
            XCTAssertEqual(accepted.items, setup.draft.items)
            XCTAssertEqual(accepted.archive, setup.draft.archive)
            XCTAssertEqual(accepted.captionInput, setup.draft.captionInput)
            let queuedValue = try await sourceFactsValue(archiveReceiptMessage(setup.box, id: ids[0].nativeID))
            let queued = try XCTUnwrap(queuedValue), zip = try XCTUnwrap(queued.media.first as? TelegramMediaFile)
            XCTAssertEqual(queued.media.count, 1)
            XCTAssertEqual(queued.text, "😀 Bold")
            XCTAssertNil(queued.groupingKey)
            XCTAssertEqual(zip.fileName, "Telegram Archive.zip")
            XCTAssertEqual(zip.mimeType, "application/zip")
            let cached = try await sourceFactsValue(setup.box.mediaBox.resourceData(zip.resource,
                pathExtension: nil, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: true) |> take(1))
            XCTAssertTrue(cached.complete)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cached.path)), setup.zipBytes)
            let replayed = expectation(description: "Frozen bundle replay refused")
            let replay = provider.submit(bundle: setup.bundle, draft: setup.draft, target: setup.fixture.target,
                receive: { if $0 == .rejected { replayed.fulfill() } })
            defer { replay.stop() }
            await fulfillment(of: [replayed], timeout: 20)
            let retained = try await sourceFactsLoad(setup.fixture.session(setup.box))
            XCTAssertEqual(retained, accepted)
            XCTAssertEqual(try setup.fixture.localRecords(), setup.localRecords)
            XCTAssertEqual(try eventCount(setup.fixture), setup.events)
            if !enabled {
                for record in setup.draft.items.map(\.file) + [try XCTUnwrap(setup.draft.archive?.file)] {
                    let object = try await S3ObjectStore(configuration: setup.fixture.configuration).head(key: record.objectKey)
                    XCTAssertNil(object)
                }
            }
            // Stopping the provider does not own/discard the caller's recovered stages.
            lease.stop()
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(setup.bundle.archive?.file.url)), setup.zipBytes)
        }
    }

    // Catches accidentally opening the legacy array route when adding whole-bundle support.
    func testArraySubmissionCannotDropTheRetainedArchive() async throws {
        let setup = try await prepared()
        defer { try? setup.bundle.discard() }
        var events: [TelegramUploadBatchEvent] = []
        let lease = TelegramUploadBatchSubmission(postbox: setup.box, accountID: 1, items: setup.bundle.items,
            draft: setup.draft, target: setup.fixture.target, enqueue: { receipt, messages in
                telegramUploadBatchEnqueueLocally(postbox: setup.box, receipt: receipt, messages: messages)
            }, receive: { events.append($0) })
        defer { lease.stop() }
        XCTAssertEqual(events, [.rejected])
        let pointer = try await sourceFactsLoad(setup.fixture.session(setup.box))
        XCTAssertEqual(pointer, setup.draft)
        XCTAssertEqual(try setup.fixture.localRecords(), setup.localRecords)
        XCTAssertEqual(try eventCount(setup.fixture), setup.events)
    }

    // Catches trusting a ZIP's existence without binding its members and the whole canonical bundle.
    func testWholeBundleSubmissionRejectsSubstitutedOrDamagedResources() async throws {
        for mutation in ["missingZIP", "missingItem", "order", "memberName", "memberDigest", "rawBytes", "zipBytes", "canonicalBytes", "scope"] {
            let setup = try await prepared(includePhoto: mutation == "canonicalBytes")
            defer { try? setup.bundle.discard() }
            let archive = try XCTUnwrap(setup.bundle.archive)
            var items = setup.bundle.items, members = archive.members
            var zip: TelegramUploadArchiveIO.Archive? = archive
            var target = setup.fixture.target
            switch mutation {
            case "missingZIP": zip = nil
            case "missingItem": items.removeLast()
            case "order": items.reverse()
            case "memberName", "memberDigest":
                let first = members[0]
                members[0] = .init(itemID: first.itemID, sourceName: first.sourceName,
                    entryName: mutation == "memberName" ? "substituted.txt" : first.entryName,
                    byteCount: first.byteCount, plaintextSHA256: mutation == "memberDigest" ? String(repeating: "0", count: 64) : first.plaintextSHA256)
                zip = .init(file: archive.file, members: members)
            case "rawBytes", "zipBytes", "canonicalBytes":
                let file = mutation == "zipBytes" ? archive.file : mutation == "canonicalBytes" ? items[0].file : items[0].rawSource
                var bytes = try Data(contentsOf: file.url); bytes[bytes.count / 2] ^= 1
                try bytes.write(to: file.url)
            case "scope": target = .init(accountID: 2, chatID: 42, title: "Other synthetic account")
            default: XCTFail("Unknown mutation")
            }
            let terminal = expectation(description: "Reject \(mutation)")
            var events: [TelegramUploadBatchEvent] = []
            let lease = TelegramUploadBatchSubmission(postbox: setup.box, accountID: 1,
                bundle: .init(items: items, archive: zip), draft: setup.draft, target: target,
                enqueue: { receipt, messages in
                    telegramUploadBatchEnqueueLocally(postbox: setup.box, receipt: receipt, messages: messages)
                }, receive: { event in events.append(event); if event == .rejected { terminal.fulfill() } })
            defer { lease.stop() }
            await fulfillment(of: [terminal], timeout: 20)
            XCTAssertEqual(events, [.rejected], mutation)
            let pointer = try await sourceFactsLoad(setup.fixture.session(setup.box))
            XCTAssertEqual(pointer, setup.draft, mutation)
            XCTAssertEqual(try setup.fixture.localRecords(), setup.localRecords)
            XCTAssertEqual(try eventCount(setup.fixture), setup.events)
        }
    }

    // Catches asynchronous validation committing after its lease has been stopped.
    func testStoppingWholeBundleBeforePreparationOrAtCommitBoundaryDoesNotEnqueue() async throws {
        for atCommit in [false, true] {
            let setup = try await prepared()
            defer { try? setup.bundle.discard() }
            let boundary = expectation(description: "Stopped bundle")
            boundary.isInverted = !atCommit
            var lease: TelegramUploadBatchSubmission?
            var events: [TelegramUploadBatchEvent] = []
            lease = TelegramUploadBatchSubmission(postbox: setup.box, accountID: 1, bundle: setup.bundle,
                draft: setup.draft, target: setup.fixture.target, enqueue: { receipt, messages in
                    telegramUploadBatchEnqueueLocally(postbox: setup.box, receipt: receipt, messages: messages)
                }, receive: { event in
                    events.append(event)
                    if atCommit, event == .committing { lease?.stop(); boundary.fulfill() }
                    else if !atCommit { boundary.fulfill() }
                })
            defer { lease?.stop() }
            if !atCommit { lease?.stop() }
            await fulfillment(of: [boundary], timeout: atCommit ? 20 : 0.1)
            XCTAssertEqual(events, atCommit ? [.committing] : [])
            let pointer = try await sourceFactsLoad(setup.fixture.session(setup.box))
            XCTAssertEqual(pointer, setup.draft)
            XCTAssertEqual(try setup.fixture.localRecords(), setup.localRecords)
            XCTAssertEqual(try eventCount(setup.fixture), setup.events)
        }
    }

    // Catches sending N originals or a separate caption instead of one authenticated ZIP.
    func testOneZIPEnqueuesAndRetainsCanonicalPreparationUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            let setup = try await prepared(enabled: enabled)
            defer { try? setup.bundle.discard() }
            let resource = try await preparedResource(setup)
            let receipt: TelegramUploadBatchEnqueueReceipt
            do { receipt = try .init(draft: setup.draft, target: setup.fixture.target, resources: [resource], groupKeys: []) }
            catch { XCTFail("One durable ZIP must have its own native receipt: \(error)"); continue }
            XCTAssertEqual(receipt.plan.groupCount, 0)
            XCTAssertEqual(receipt.plan.messages.count, 1)
            XCTAssertEqual(receipt.plan.messages.first?.itemID, setup.draft.archive?.id)
            XCTAssertEqual(receipt.plan.messages.first?.caption.text, "😀 Bold")
            XCTAssertEqual(receipt.plan.messages.first?.caption.entities, [.init(offset: 0, length: 2, kind: .bold)])
            XCTAssertNil(receipt.plan.messages.first?.groupIndex)
            XCTAssertEqual(receipt.plan.messages.first?.captionAboveMedia, false)
            XCTAssertEqual(receipt.plan.messages.first?.mediaSpoiler, false)
            let messages = try XCTUnwrap(receipt.messages(replySource: nil))
            XCTAssertEqual(messages.count, 1)
            let admission = try await sourceFactsValue(telegramUploadBatchEnqueueLocally(postbox: setup.box,
                receipt: receipt, messages: messages, loseAcknowledgement: !enabled))
            if enabled {
                guard case let .accepted(ids) = admission else { XCTFail("Complete ZIP receipt must acknowledge native insertion"); continue }
                XCTAssertEqual(ids.count, 1)
            } else {
                guard case .uncertain = admission else { XCTFail("Lost ACK must remain uncertain"); continue }
            }
            let accepted = try await sourceFactsLoad(setup.fixture.session(setup.box))
            guard case let .acceptedBatch(ids) = accepted.disposition, ids.count == 1 else {
                XCTFail("Native transaction must retain exactly one accepted ZIP ID"); continue
            }
            XCTAssertEqual(accepted.items, setup.draft.items)
            XCTAssertEqual(accepted.archive, setup.draft.archive)
            XCTAssertEqual(accepted.captionInput, setup.draft.captionInput)
            XCTAssertEqual(accepted.captionInput.formattedText.text, "  😀 Bold  ")
            let queuedValue = try await sourceFactsValue(archiveReceiptMessage(setup.box, id: ids[0].nativeID))
            let queued = try XCTUnwrap(queuedValue)
            XCTAssertEqual(queued.text, "😀 Bold")
            XCTAssertEqual(queued.textEntitiesAttribute?.entities, [.init(range: 0..<2, type: .Bold)])
            XCTAssertNil(queued.groupingKey)
            XCTAssertEqual(queued.media.count, 1)
            let file = try XCTUnwrap(queued.media.first as? TelegramMediaFile)
            XCTAssertEqual(file.mimeType, "application/zip")
            XCTAssertEqual(file.fileName, "Telegram Archive.zip")
            XCTAssertEqual(file.size, setup.bundle.archive?.file.size)
            XCTAssertTrue(file.previewRepresentations.isEmpty)
            XCTAssertNil(file.videoCover)
            XCTAssertFalse(queued.attributes.contains { $0 is InvertMediaMessageAttribute || $0 is MediaSpoilerMessageAttribute })
            let cache = try await sourceFactsValue(setup.box.mediaBox.resourceData(file.resource,
                pathExtension: nil, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: true) |> take(1))
            XCTAssertTrue(cache.complete)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cache.path)), setup.zipBytes)
            let replay = try await sourceFactsValue(telegramUploadBatchEnqueueLocally(postbox: setup.box, receipt: receipt, messages: messages))
            guard case .rejected = replay else { XCTFail("Accepted ZIP must never enqueue twice"); continue }
            let retained = try await sourceFactsLoad(setup.fixture.session(setup.box))
            XCTAssertEqual(retained, accepted)
            XCTAssertEqual(try setup.fixture.localRecords(), setup.localRecords)
            XCTAssertEqual(try eventCount(setup.fixture), setup.events)
            if !enabled {
                let records = setup.draft.items.map(\.file) + [try XCTUnwrap(setup.draft.archive?.file)]
                for record in records {
                    let object = try await S3ObjectStore(configuration: setup.fixture.configuration).head(key: record.objectKey)
                    XCTAssertNil(object)
                }
            }
        }
    }

    // Catches treating a raw source or substituted ZIP metadata as the one archive resource.
    func testReceiptRefusesCanonicalSourcesAndAlteredZIPCapabilities() async throws {
        let setup = try await prepared()
        defer { try? setup.bundle.discard() }
        let good = try await preparedResource(setup)
        let receipt: TelegramUploadBatchEnqueueReceipt
        do { receipt = try .init(draft: setup.draft, target: setup.fixture.target, resources: [good], groupKeys: []) }
        catch { return XCTFail("Valid archive receipt is required before testing substitution: \(error)") }
        XCTAssertEqual(receipt.plan.messages.count, 1)
        let raw = try await preparedResource(setup, item: setup.bundle.items[0], digest: setup.draft.items[0].file.plaintextSHA256)
        let wrongID = try await preparedResource(setup, item: .init(id: UUID(), file: good.item.file))
        let wrongDigest = try await preparedResource(setup, digest: String(repeating: "0", count: 64), verifyDigest: false)
        let original = try await preparedResource(setup, item: .init(id: good.item.id, file: good.item.file,
            originalFile: setup.bundle.items[0].file))
        let facts = TelegramUploadSourceFacts(itemID: good.item.id, role: .prepared, name: good.item.file.name,
            byteCount: good.item.file.size, plaintextSHA256: good.plaintextSHA256, selectionMIME: "application/zip",
            image: .notImage, grouping: .ordinary)
        let rawFacts = try await preparedResource(setup, item: .init(id: good.item.id, file: good.item.file, sourceFacts: facts))
        for resources in [[], [raw], [good, raw], [wrongID], [wrongDigest], [original], [rawFacts]] {
            XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: setup.draft,
                target: setup.fixture.target, resources: resources, groupKeys: []))
        }
        XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: setup.draft,
            target: setup.fixture.target, resources: [good], groupKeys: [7]))
        XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: setup.draft,
            target: .init(accountID: 2, chatID: 42, title: "Other account"), resources: [good], groupKeys: []))
        let pointer = try await sourceFactsLoad(setup.fixture.session(setup.box))
        XCTAssertEqual(pointer, setup.draft)
    }

    // Catches admitting a frozen ZIP against a later caption revision.
    func testStaleArchiveReceiptCannotEnqueueOverNewerPointer() async throws {
        let setup = try await prepared()
        defer { try? setup.bundle.discard() }
        let resource = try await preparedResource(setup)
        let receipt: TelegramUploadBatchEnqueueReceipt
        do { receipt = try .init(draft: setup.draft, target: setup.fixture.target, resources: [resource], groupKeys: []) }
        catch { return XCTFail("Valid archive receipt must reach native CAS: \(error)") }
        let newer = setup.draft.updating(captionInput: try .init(formattedText: .init(text: "New caption")),
            captionAboveMedia: false, mediaSpoiler: false, disposition: .submissionStarted)
        try (await sourceFactsValue(archiveReceiptWrite(setup.box, draft: newer, expected: setup.draft.revision))).get()
        let admission = try await sourceFactsValue(telegramUploadBatchEnqueueLocally(postbox: setup.box,
            receipt: receipt, messages: XCTUnwrap(receipt.messages(replySource: nil))))
        guard case .rejected = admission else { return XCTFail("Stale archive must not insert a native message") }
        let pointer = try await sourceFactsLoad(setup.fixture.session(setup.box))
        XCTAssertEqual(pointer, newer)
        XCTAssertEqual(try setup.fixture.localRecords(), setup.localRecords)
        XCTAssertEqual(try eventCount(setup.fixture), setup.events)
    }

    // Catches accepting an injected media lifetime while preserving legitimate chat auto-delete.
    func testArchiveReceiptRefusesInjectedMediaTTLAndAllowsChatAutoremove() async throws {
        for forged in [false, true] {
            let setup = try await prepared(chatTTL: true)
            defer { try? setup.bundle.discard() }
            let resource = try await preparedResource(setup)
            let receipt = try TelegramUploadBatchEnqueueReceipt(draft: setup.draft, target: setup.fixture.target,
                resources: [resource], groupKeys: [])
            let messages = try XCTUnwrap(receipt.messages(replySource: nil))
            let admission = try await sourceFactsValue(archiveReceiptTTLQueue(setup.box, receipt: receipt,
                messages: messages, forged: forged))
            let pointer = try await sourceFactsLoad(setup.fixture.session(setup.box))
            if forged {
                guard case .uncertain = admission else {
                    XCTFail("A queued ZIP with injected media TTL cannot receive a complete acceptance receipt"); continue
                }
                XCTAssertEqual(pointer, setup.draft)
            } else {
                guard case let .accepted(ids) = admission, ids.count == 1 else {
                    XCTFail("Chat auto-delete must not be confused with explicit media TTL"); continue
                }
                let queued = try await sourceFactsValue(archiveReceiptMessage(setup.box, id: ids[0]))
                let message = try XCTUnwrap(queued)
                XCTAssertEqual(message.attributes.compactMap { ($0 as? AutoremoveTimeoutMessageAttribute)?.timeout }, [30])
                XCTAssertTrue(message.attributes.allSatisfy { !($0 is AutoclearTimeoutMessageAttribute) })
                guard case .acceptedBatch = pointer.disposition else { return XCTFail("Honest ZIP receipt must persist") }
            }
            XCTAssertEqual(try setup.fixture.localRecords(), setup.localRecords)
            XCTAssertEqual(try eventCount(setup.fixture), setup.events)
        }
    }

    private struct Setup {
        let fixture: SourceFactsTestArchive
        let box: Postbox
        let draft: TelegramPendingUploadDraft
        let bundle: TelegramRecoveredUploadBundle
        let zipBytes: Data
        let localRecords: [String]
        let events: [[String]]
    }

    private func prepared(enabled: Bool = false, chatTTL: Bool = false, includePhoto: Bool = false, accountID: Int64 = 1) async throws -> Setup {
        let fixture = try await sourceFactsArchive(accountID: accountID), box = try await sourceFactsOpen(fixture.postboxPath)
        try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
        try await sourceFactsValue(archiveReceiptPeers(box, chatTTL: chatTTL))
        let first = try await includePhoto ? sourceFactsSmallImage(fixture) : sourceFactsDocument(fixture, name: "first.txt", text: "First synthetic source")
        let items = [first,
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "Second synthetic source")]
        defer { items.forEach { try? $0.discard() } }
        let store = fixture.session(box), id = UUID()
        let input = try TelegramComposerInput(formattedText: .init(text: "  😀 Bold  ",
            entities: [.init(offset: 2, length: 2, kind: .bold)]), selection: .init(location: 2, length: 2))
        try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
            target: fixture.target, captionInput: input, originalDraft: nil)
        let pending = try await sourceFactsLoad(store)
        let sources = items.map { TelegramUploadArchiveIO.Source(itemID: $0.id, file: $0.rawSource) }
        let zip = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(zip.file) }
        let record = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(zip,
            sources: sources, archiveID: zip.file.id, accountID: accountID, chatID: 42, preparationID: id)
        let descriptor = TelegramPendingUploadArchive(id: zip.file.id, file: record,
            members: zip.members.map { .init(itemID: $0.itemID, entryName: $0.entryName) })
        _ = try await store.installArchive(preparationID: id, expectedRevision: pending.revision, archive: descriptor,
            target: fixture.target, admission: .init(accountID: accountID, chatID: 42, preparationID: id,
                expectedRevision: pending.revision, generation: UUID()))
        try await store.save(preparationID: id, chatID: 42, captionInput: input, disposition: .submissionStarted)
        let draft = try await sourceFactsLoad(store), bundle = try await store.restoreBundle(draft: draft)
        return .init(fixture: fixture, box: box, draft: draft, bundle: bundle,
            zipBytes: try Data(contentsOf: zip.file.url), localRecords: try fixture.localRecords(), events: try eventCount(fixture))
    }

    private func preparedResource(_ setup: Setup, item: TelegramUploadBatchItem? = nil, digest: String? = nil,
                                  verifyDigest: Bool = true) async throws -> TelegramUploadBatchResource {
        let descriptor = try XCTUnwrap(setup.draft.archive)
        let item = try item ?? .init(id: descriptor.id, file: XCTUnwrap(setup.bundle.archive?.file))
        let digest = digest ?? descriptor.file.plaintextSHA256
        let ready = expectation(description: "Real ZIP MediaBox copy")
        var result: Result<TelegramPreparedUploadMedia, TelegramUploadFileError>?
        let lease = TelegramUploadMediaBoxPreparation(mediaBox: setup.box.mediaBox, file: item.file,
            expectedPlaintextSHA256: verifyDigest ? digest : nil) { result = $0; ready.fulfill() }
        defer { lease.stop() }
        await fulfillment(of: [ready], timeout: 20)
        return .init(item: item, plaintextSHA256: digest, prepared: try XCTUnwrap(result).get())
    }

    private func eventCount(_ fixture: SourceFactsTestArchive) throws -> [[String]] {
        try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events")
    }
}

private nonisolated func archiveReceiptWrite(_ box: Postbox, draft: TelegramPendingUploadDraft, expected: UUID)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    box.transaction { telegramPendingUploadWrite(transaction: $0, accountID: draft.accountID, draft: draft, expectedRevision: expected) }
}

private nonisolated func archiveReceiptMessage(_ box: Postbox, id: MessageId) -> Signal<Message?, NoError> {
    box.transaction { $0.getMessage(id) }
}

private nonisolated func archiveReceiptPeers(_ box: Postbox, chatTTL: Bool) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let users = [PeerId(1), PeerId(42)].map {
            TelegramUser(id: $0, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
                photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
                nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
                subscriberCount: nil, verificationIconFileId: nil)
        }
        transaction.updatePeersInternal(users, update: { current, new in current ?? new })
        transaction.updatePeerCachedData(peerIds: [PeerId(42)], update: { _, _ in
            chatTTL ? CachedUserData().withUpdatedAutoremoveTimeout(.known(.init(peerValue: 30))) : CachedUserData()
        })
    }
}

private nonisolated func archiveReceiptTTLQueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
    messages: [EnqueueMessage], forged: Bool) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(receipt.target.chatID), messages: messages, transactionAdmission: admission,
            transactionCommit: { transaction, ids in
                if forged, let first = ids.first, let id = first, let message = transaction.getMessage(id) {
                    transaction.updateMessage(id) { _ in .update(StoreMessage(id: id, globallyUniqueId: nil,
                        groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp,
                        flags: [.Unsent], tags: message.tags, globalTags: message.globalTags, localTags: message.localTags,
                        forwardInfo: nil, authorId: PeerId(1), text: message.text,
                        attributes: message.attributes + [AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout,
                            countdownBeginTime: nil)], media: message.media)) }
                }
                commit(transaction, ids)
            })
    }
}
