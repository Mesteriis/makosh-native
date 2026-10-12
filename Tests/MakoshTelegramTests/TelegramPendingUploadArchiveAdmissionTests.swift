import XCTest
import Foundation
import MakoshCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadArchiveAdmissionTests: TelegramSourceFactsIntegrationTestCase {
    // Catches stale capture metadata surviving an edit/cancellation/install or original-UUID A→B→A.
    func testCaptureReceiptPreservesExactNoOpAndClearsOnChangingPointerWrites() async throws {
        for mutation in ["caption", "roundTrip", "cancel", "install"] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let (current, candidate) = try await makeCandidate(fixture, box: box)
            let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
            try await retain(repository, candidate, current.revision, admission(current)).get()
            try await save(repository, current, current.revision)
            let retained = try await fixture.session(box).loadArchiveCapture(chatID: 42)
            XCTAssertEqual(retained?.candidate, candidate)
            let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, current)
            if mutation == "install" {
                try await install(repository, candidate, current.revision, admission(current)).get()
            } else {
                let changed = current.updating(captionInput: try .init(formattedText: .init(text: "Later edit")),
                    captionAboveMedia: false, mediaSpoiler: false, disposition: mutation == "cancel" ? .cancelled : .prepared)
                try await save(repository, changed, current.revision)
                if mutation == "roundTrip" { try await save(repository, current, changed.revision) }
            }
            let removed = try await fixture.session(box).loadArchiveCapture(chatID: 42); XCTAssertNil(removed)
        }
    }

    // Catches overwriting the retained ZIP candidate, or retaining through cancelled/stale native admission.
    func testCaptureRetentionRefusesReplacementWrongRevisionAndCancelledAdmission() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let (current, candidate) = try await makeCandidate(fixture, box: box)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let cancelled = admission(current); cancelled.cancel()
        assertConflict(await retain(repository, candidate, current.revision, cancelled))
        let absent = try await fixture.session(box).loadArchiveCapture(chatID: 42); XCTAssertNil(absent)
        try await retain(repository, candidate, current.revision, admission(current)).get()
        try await retain(repository, candidate, current.revision, admission(current)).get()
        let replacement = try TelegramPendingUploadDraft(id: candidate.id, accountID: 1, chatID: 42,
            title: candidate.title, captionInput: candidate.captionInput, originalDraft: candidate.originalDraft,
            replyTarget: candidate.replyTarget, items: candidate.items, isGrouped: false,
            presentation: .archive, archive: candidate.archive)
        assertConflict(await retain(repository, replacement, current.revision, admission(current)))
        let foreign = UUID(), foreignToken = TelegramPendingUploadArchiveAdmission(accountID: 1, chatID: 42,
            preparationID: current.id, expectedRevision: foreign, generation: UUID())
        assertConflict(await retain(repository, candidate, foreign, foreignToken))
        let retained = try await fixture.session(box).loadArchiveCapture(chatID: 42)
        XCTAssertEqual(retained?.candidate, candidate)
        let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, current)
    }

    // Catches accepting corrupted receipts, foreign scopes or changed predecessor bytes with the same UUID.
    func testCaptureReadRejectsCorruptionForeignScopeAndChangedPredecessorBytes() async throws {
        for mutation in ["corrupt", "foreign", "base"] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let (current, candidate) = try await makeCandidate(fixture, box: box)
            let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
            try await retain(repository, candidate, current.revision, admission(current)).get()
            let changed = try await sourceFactsValue(archiveCaptureMutate(box, current: current, mutation: mutation))
            XCTAssertTrue(changed)
            do {
                _ = try await fixture.session(box).loadArchiveCapture(chatID: mutation == "foreign" ? 43 : 42)
                XCTFail("An invalid capture receipt was exposed: \(mutation)")
            } catch let error as TelegramPendingUploadPersistenceError {
                XCTAssertEqual(error, mutation == "corrupt" ? .incompatibleData : .conflict)
            }
        }
    }

    // Catches treating any predecessor revision as the origin of an already installed candidate.
    func testExactReplayRejectsForeignPredecessorRevision() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let (current, candidate) = try await makeCandidate(fixture, box: box)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let first = await install(repository, candidate, current.revision, admission(current))
        guard case .success = first else { return XCTFail("First guarded installation must succeed") }
        let foreign = UUID()
        let token = TelegramPendingUploadArchiveAdmission(accountID: 1, chatID: 42, preparationID: current.id,
            expectedRevision: foreign, generation: UUID())
        assertConflict(await install(repository, candidate, foreign, token))
        let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, candidate)
    }

    // Catches acknowledging a schema16 written by an unrelated generic path without guarded-install provenance.
    func testExactCandidateWithoutGuardedInstallationReceiptCannotReplay() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let (current, candidate) = try await makeCandidate(fixture, box: box)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        try await save(repository, candidate, current.revision)
        assertConflict(await install(repository, candidate, current.revision, admission(current)))
        let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, candidate)
    }

    // Catches replaying A after ordinary writes A→B→A reuse A's original revision UUID.
    func testOrdinaryWriteInvalidatesReceiptEvenWhenOriginalRevisionIsReused() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let (current, candidate) = try await makeCandidate(fixture, box: box)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let first = await install(repository, candidate, current.revision, admission(current))
        guard case .success = first else { return XCTFail("First guarded installation must succeed") }
        let changed = candidate.updating(captionInput: try .init(formattedText: .init(text: "Intermediate edit")),
            captionAboveMedia: false, mediaSpoiler: false, disposition: .prepared)
        try await save(repository, changed, candidate.revision)
        try await save(repository, candidate, changed.revision)
        let restored = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(restored, candidate)
        assertConflict(await install(repository, candidate, current.revision, admission(current)))
        let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, candidate)
    }

    // Catches trusting a missing, damaged or differently scoped receipt for an otherwise exact replay.
    func testReplayRefusesDeletedCorruptOrForeignScopeReceipt() async throws {
        for mutation in ["deleted", "corrupt", "foreign"] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let (current, candidate) = try await makeCandidate(fixture, box: box)
            let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
            let first = await install(repository, candidate, current.revision, admission(current))
            guard case .success = first else { return XCTFail("First guarded installation must succeed") }
            let changed = try await sourceFactsValue(archiveInstallCorruptReceipt(box, mutation: mutation))
            XCTAssertTrue(changed, "The first native transaction must persist its receipt")
            assertConflict(await install(repository, candidate, current.revision, admission(current)))
            let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, candidate)
        }
    }

    // Catches a native write dropping canonical state, or a retained retry creating another revision.
    func testNativeInstallPreservesResourcesAndExactRetainedRetry() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let (current, candidate) = try await makeCandidate(fixture, box: box)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let token = admission(current)
        let first = await install(repository, candidate, current.revision, token)
        guard case .success = first else { return XCTFail("A valid Archive install was refused: \(first)") }
        let installed = try await sourceFactsLoad(fixture.session(box))
        XCTAssertEqual(installed, candidate)
        XCTAssertEqual(installed.schemaVersion, 16)
        XCTAssertEqual(installed.items, current.items)
        XCTAssertEqual(installed.captionInput, current.captionInput)
        XCTAssertEqual(installed.originalDraft, current.originalDraft)
        XCTAssertEqual(installed.replyTarget, current.replyTarget)
        XCTAssertFalse(installed.isGrouped); XCTAssertFalse(installed.captionAboveMedia); XCTAssertFalse(installed.mediaSpoiler)
        try await save(repository, candidate, current.revision) // An exact no-op must preserve install provenance.
        let retry = await install(repository, candidate, current.revision, token)
        guard case .success = retry else { return XCTFail("An exact retained retry was refused: \(retry)") }
        let repeated = try await sourceFactsLoad(fixture.session(box))
        XCTAssertEqual(repeated.revision, candidate.revision)
        for invalid in [
            TelegramPendingUploadArchiveAdmission(accountID: 2, chatID: 42, preparationID: current.id, expectedRevision: current.revision, generation: UUID()),
            TelegramPendingUploadArchiveAdmission(accountID: 1, chatID: 43, preparationID: current.id, expectedRevision: current.revision, generation: UUID()),
            TelegramPendingUploadArchiveAdmission(accountID: 1, chatID: 42, preparationID: UUID(), expectedRevision: current.revision, generation: UUID()),
            TelegramPendingUploadArchiveAdmission(accountID: 1, chatID: 42, preparationID: current.id, expectedRevision: UUID(), generation: UUID())
        ] { assertConflict(await install(repository, candidate, current.revision, invalid)) }
        token.cancel()
        assertConflict(await install(repository, candidate, current.revision, token))
        let afterCancel = try await sourceFactsLoad(fixture.session(box))
        XCTAssertEqual(afterCancel, candidate)
    }

    // Catches cancellation checked only on MainActor, before a write waits in the native queue.
    func testCancellationWhileNativeQueueIsHeldLeavesOldPointer() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let (current, candidate) = try await makeCandidate(fixture, box: box)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1), token = admission(current)
        let gate = ArchiveAdmissionQueueGate()
        let held = holdArchiveAdmissionQueue(box, gate: gate).start()
        defer { gate.release.signal(); held.dispose() }
        let entered = await Task.detached { gate.waitForEntry() }.value
        XCTAssertTrue(entered, "Native transaction did not enter the test gate")
        guard entered else { return }
        let completed = expectation(description: "guarded native completion")
        var result: Result<Void, TelegramPendingUploadPersistenceError>?
        repository.installArchive(candidate, expectedRevision: current.revision, admission: token) {
            result = $0; completed.fulfill()
        }
        XCTAssertNil(result, "A native install must wait for its transaction")
        token.cancel(); gate.release.signal()
        await fulfillment(of: [completed], timeout: 20)
        assertConflict(try XCTUnwrap(result))
        let after = try await sourceFactsLoad(fixture.session(box))
        XCTAssertEqual(after, current)
    }

    // Catches an obsolete Archive operation overwriting a later caption or submission state.
    func testStaleRevisionAndNonPreparedPointerCannotBeOverwritten() async throws {
        for disposition in [TelegramPendingUploadDisposition.prepared, .submissionStarted, .cancelled] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let (current, candidate) = try await makeCandidate(fixture, box: box)
            let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
            let changed = current.updating(captionInput: try .init(formattedText: .init(text: "later caption")),
                captionAboveMedia: false, mediaSpoiler: false, disposition: disposition)
            try await save(repository, changed, current.revision)
            assertConflict(await install(repository, candidate, current.revision, admission(current)))
            if disposition != .prepared {
                let terminalCandidate = try TelegramPendingUploadDraft(id: changed.id, accountID: 1, chatID: 42,
                    title: changed.title, captionInput: changed.captionInput, originalDraft: changed.originalDraft,
                    replyTarget: changed.replyTarget, items: changed.items, isGrouped: false,
                    presentation: .archive, archive: candidate.archive)
                assertConflict(await install(repository, terminalCandidate, changed.revision, admission(changed)))
            }
            let after = try await sourceFactsLoad(fixture.session(box))
            XCTAssertEqual(after, changed)
        }
    }

    // Catches String's canonical equality accepting different opaque UTF8 metadata during CAS.
    func testNativeInstallCannotSubstituteCanonicalEquivalentTitleOrCaption() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let (current, candidate) = try await makeCandidate(fixture, box: box, title: "Cafe\u{301}")
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let forged = try TelegramPendingUploadDraft(id: candidate.id, revision: candidate.revision,
            accountID: 1, chatID: 42, title: "Caf\u{e9}", captionInput: candidate.captionInput,
            originalDraft: candidate.originalDraft, replyTarget: candidate.replyTarget, items: candidate.items,
            isGrouped: false, presentation: .archive, archive: candidate.archive)
        XCTAssertTrue(forged.isValid)
        XCTAssertEqual(forged.title, current.title)
        XCTAssertNotEqual(Data(forged.title.utf8), Data(current.title.utf8))
        assertConflict(await install(repository, forged, current.revision, admission(current)))
        let replaced = try TelegramPendingUploadDraft(id: candidate.id, revision: UUID(), accountID: 1,
            chatID: 42, title: current.title, captionInput: try .init(formattedText: .init(text: "substituted caption")),
            originalDraft: candidate.originalDraft, replyTarget: candidate.replyTarget, items: candidate.items,
            isGrouped: false, presentation: .archive, archive: candidate.archive)
        XCTAssertTrue(replaced.isValid)
        assertConflict(await install(repository, replaced, current.revision, admission(current)))
        let after = try await sourceFactsLoad(fixture.session(box))
        XCTAssertEqual(after.revision, current.revision)
        XCTAssertEqual(Data(after.title.utf8), Data(current.title.utf8))
    }

    // Catches a token escaping its account/chat/preparation/revision or an invalid generation.
    func testAdmissionBindsScopeAndRejectsCancellationOrZeroGeneration() throws {
        let preparation = UUID(), revision = UUID(), generation = UUID()
        let token = TelegramPendingUploadArchiveAdmission(accountID: 1, chatID: 42,
            preparationID: preparation, expectedRevision: revision, generation: generation)
        XCTAssertNoThrow(try token.check(accountID: 1, chatID: 42, preparationID: preparation, expectedRevision: revision))
        for (account, chat, preparationID, expectedRevision) in [(Int64(2), Int64(42), preparation, revision),
            (1, 43, preparation, revision), (1, 42, UUID(), revision), (1, 42, preparation, UUID())] {
            XCTAssertThrowsError(try token.check(accountID: account, chatID: chat,
                preparationID: preparationID, expectedRevision: expectedRevision)) {
                XCTAssertEqual($0 as? TelegramPendingUploadPersistenceError, .conflict)
            }
        }
        let invalid = TelegramPendingUploadArchiveAdmission(accountID: 1, chatID: 42,
            preparationID: preparation, expectedRevision: revision, generation: TelegramPendingUploadDraft.zeroUUID)
        XCTAssertThrowsError(try invalid.check(accountID: 1, chatID: 42, preparationID: preparation, expectedRevision: revision)) {
            XCTAssertEqual($0 as? TelegramPendingUploadPersistenceError, .conflict)
        }
        token.cancel()
        XCTAssertThrowsError(try token.check(accountID: 1, chatID: 42, preparationID: preparation, expectedRevision: revision)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    private func makeCandidate(_ fixture: SourceFactsTestArchive, box: Postbox, title: String = "Synthetic admission")
        async throws -> (TelegramPendingUploadDraft, TelegramPendingUploadDraft) {
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "first native admission"),
                     try await sourceFactsDocument(fixture, name: ".second.txt", text: "second native admission")]
        defer { items.forEach { try? $0.discard() } }
        let store = fixture.session(box), preparation = UUID()
        try await store.prepare(preparationID: preparation, items: items, isGrouped: false, presentation: .file,
            target: .init(accountID: 1, chatID: 42, title: title),
            captionInput: try .init(formattedText: .init(text: "original caption")), originalDraft: nil)
        let current = try await sourceFactsLoad(store)
        let sources = items.map { TelegramUploadArchiveIO.Source(itemID: $0.id, file: $0.rawSource) }
        let zip = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(zip.file) }
        let record = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(zip, sources: sources,
            archiveID: zip.file.id, accountID: 1, chatID: 42, preparationID: preparation)
        let descriptor = TelegramPendingUploadArchive(id: zip.file.id, file: record,
            members: zip.members.map { .init(itemID: $0.itemID, entryName: $0.entryName) })
        let candidate = try TelegramPendingUploadDraft(id: current.id, accountID: 1, chatID: 42,
            title: current.title, captionInput: current.captionInput, originalDraft: current.originalDraft,
            replyTarget: current.replyTarget, items: current.items, isGrouped: false, presentation: .archive, archive: descriptor)
        XCTAssertTrue(current.isValid); XCTAssertTrue(candidate.isValid)
        return (current, candidate)
    }

    private func admission(_ draft: TelegramPendingUploadDraft) -> TelegramPendingUploadArchiveAdmission {
        .init(accountID: draft.accountID, chatID: draft.chatID, preparationID: draft.id,
              expectedRevision: draft.revision, generation: UUID())
    }
    private func install(_ repository: TelegramPostboxPendingUploadRepository, _ draft: TelegramPendingUploadDraft,
                         _ expected: UUID, _ token: TelegramPendingUploadArchiveAdmission)
        async -> Result<Void, TelegramPendingUploadPersistenceError> {
        await withCheckedContinuation { continuation in
            repository.installArchive(draft, expectedRevision: expected, admission: token) { continuation.resume(returning: $0) }
        }
    }
    private func save(_ repository: TelegramPostboxPendingUploadRepository, _ draft: TelegramPendingUploadDraft,
                      _ expected: UUID) async throws {
        let result: Result<Void, TelegramPendingUploadPersistenceError> = await withCheckedContinuation { continuation in
            repository.save(draft, expectedRevision: expected) { continuation.resume(returning: $0) }
        }
        try result.get()
    }
    private func retain(_ repository: TelegramPostboxPendingUploadRepository, _ draft: TelegramPendingUploadDraft,
                        _ expected: UUID, _ token: TelegramPendingUploadArchiveAdmission)
        async -> Result<Void, TelegramPendingUploadPersistenceError> {
        await withCheckedContinuation { continuation in
            repository.retainArchiveCapture(draft, expectedRevision: expected, admission: token) { continuation.resume(returning: $0) }
        }
    }
    private func assertConflict(_ result: Result<Void, TelegramPendingUploadPersistenceError>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(.conflict) = result else { return XCTFail("Expected conflict, got \(result)", file: file, line: line) }
    }
}

private nonisolated func archiveCaptureMutate(_ box: Postbox, current: TelegramPendingUploadDraft, mutation: String) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let key = telegramPendingUploadArchiveCaptureKey(accountID: 1, chatID: 42)
        guard let entry = transaction.getPreferencesEntry(key: key) else { return false }
        if mutation == "corrupt" {
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([0])))
        } else if mutation == "foreign" {
            transaction.setPreferencesEntry(key: telegramPendingUploadArchiveCaptureKey(accountID: 1, chatID: 43), value: entry)
        } else {
            // Deliberately bypass ordinary-write invalidation to exercise the stored base digest.
            guard let changed = try? TelegramPendingUploadDraft(id: current.id, revision: current.revision,
                accountID: 1, chatID: 42, title: current.title, captionInput: current.captionInput,
                originalDraft: current.originalDraft, replyTarget: current.replyTarget, items: current.items,
                isGrouped: !current.isGrouped, presentation: current.presentation) else { return false }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let bytes = try? encoder.encode(changed) else { return false }
            transaction.setPreferencesEntry(key: telegramPendingUploadKey(accountID: 1, chatID: 42),
                value: PreferencesEntry(data: Data("Makosh.PendingUpload.JSON.v1\n".utf8) + bytes))
        }
        return true
    }
}

private nonisolated func archiveInstallCorruptReceipt(_ box: Postbox, mutation: String) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let key = telegramPendingUploadArchiveInstallKey(accountID: 1, chatID: 42)
        guard let entry = transaction.getPreferencesEntry(key: key) else { return false }
        if mutation == "corrupt" {
            var data = entry.data; data[data.count - 1] ^= 1
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data))
        } else {
            transaction.setPreferencesEntry(key: key, value: nil)
            if mutation == "foreign" {
                transaction.setPreferencesEntry(key: telegramPendingUploadArchiveInstallKey(accountID: 2, chatID: 42), value: entry)
                transaction.setPreferencesEntry(key: telegramPendingUploadArchiveInstallKey(accountID: 1, chatID: 43), value: entry)
            }
        }
        return true
    }
}

private final class ArchiveAdmissionQueueGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
}
// No MainActor closure crosses into the engine's independent native transaction queue.
private nonisolated func holdArchiveAdmissionQueue(_ box: Postbox, gate: ArchiveAdmissionQueueGate) -> Signal<Void, NoError> {
    box.transaction { _ in
        gate.entered.signal()
        _ = gate.release.wait(timeout: .now() + 20)
    }
}
