import XCTest
import Foundation
import MakoshCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadArchiveHandoffTests: TelegramSourceFactsIntegrationTestCase {
    // Catches losing a captured ZIP before its native retention commit and creating a second immutable copy after reopen.
    func testCaptureBeforeNativeRetentionFailureReopensWithoutRecaptureForBothPolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First raw source"),
                         try await sourceFactsDocument(fixture, name: "second.txt", text: "Second raw source")]
            defer { items.forEach { try? $0.discard() } }
            let id = UUID(), input = try TelegramComposerInput(formattedText: .init(text: "Retain this ZIP 😀"))
            var attempted: TelegramPendingUploadDraft?
            weak var previous: Postbox?
            do {
                let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
                let repository = ArchiveHandoffRepository(box)
                let store = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: fixture.archive) })
                try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                    target: fixture.target, captionInput: input, originalDraft: nil)
                let before = try await sourceFactsLoad(store)
                items.forEach { try? $0.discard() }
                do {
                    try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                        previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
                    XCTFail("The pre-commit retention refusal must be reported")
                } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .unavailable) }
                attempted = try XCTUnwrap(repository.refusedCandidate)
                let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(unchanged, before)
                let absent = try await store.loadArchiveCapture(chatID: 42); XCTAssertNil(absent)
            }
            for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previous)
            let captured = try XCTUnwrap(attempted), old = try XCTUnwrap(captured.archive), count = try recordCount(fixture)
            let box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
            try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            let restored = try await sourceFactsLoad(store)
            XCTAssertEqual(restored.archive, old, "The already captured immutable ZIP must be reused")
            XCTAssertEqual(restored.revision, captured.revision, "The original installation candidate must survive the handoff")
            XCTAssertEqual(try recordCount(fixture), count, "Explicit retry must create no further file or S3 copy")
            XCTAssertEqual(restored.captionInput, input)
            let bundle = try await store.restoreBundle(draft: restored)
            XCTAssertEqual(bundle.archive?.members.map(\.entryName), ["first.txt", "second.txt"])
            try bundle.discard()
            if !enabled {
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
                let remote = try await S3ObjectStore(configuration: fixture.configuration).head(key: old.file.objectKey)
                XCTAssertNil(remote)
            }
        }
    }

    // Catches admitting an old capture after an ordinary write invalidates its reservation and restores the original UUID.
    func testChangingWriteAndOriginalUUIDRestoreCannotReviveTheCaptureIntent() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let repository = ArchiveHandoffRepository(box)
        let store = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: fixture.archive) })
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First"),
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "Second")]
        defer { items.forEach { try? $0.discard() } }
        let id = UUID()
        try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let before = try await sourceFactsLoad(store)
        repository.restoreBeforeRetention = before
        do {
            try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            XCTFail("Invalidated capture intent must not revive when an earlier UUID is restored")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(unchanged, before)
        XCTAssertEqual(try recordCount(fixture), 3, "The refused immutable ZIP remains retained")
    }

    // Catches admitting an old capture after an ordinary write invalidates its reservation and restores the original UUID.
    func testChangingWriteBeforeInstallationCannotReviveTheCaptureIntent() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let repository = ArchiveHandoffRepository(box)
        let store = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: fixture.archive) })
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First"),
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "Second")]
        defer { items.forEach { try? $0.discard() } }
        let id = UUID()
        try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let before = try await sourceFactsLoad(store)
        repository.restoreBeforeInstallation = before
        do {
            try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            XCTFail("Invalidated capture intent must not revive when an earlier UUID is restored")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(unchanged, before)
        XCTAssertEqual(try recordCount(fixture), 3, "The refused immutable ZIP remains retained")
    }

    // Catches storage capture running before native reservation acknowledgement, or losing the committed reservation on retry.
    func testReservationFailureBeforeCaptureDoesNotCreateAnotherFile() async throws {
        for committed in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let repository = ArchiveHandoffRepository(box)
            repository.failIntent = committed
            let store = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: fixture.archive) })
            let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First"),
                         try await sourceFactsDocument(fixture, name: "second.txt", text: "Second")]
            defer { items.forEach { try? $0.discard() } }
            let id = UUID()
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
            let before = try await sourceFactsLoad(store)
            do {
                try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                    previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
                XCTFail("Reservation acknowledgement failure must be reported before capturing ZIP bytes")
            } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .unavailable) }
            XCTAssertEqual(try recordCount(fixture), 2)
            let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(unchanged, before)
            let reserved = try await sourceFactsValue(handoffReadIntent(box)).get()
            XCTAssertEqual(reserved != nil, committed)
            let retry = fixture.session(box)
            try await retry.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            let installed = try await sourceFactsLoad(retry)
            XCTAssertEqual(try recordCount(fixture), 3)
            if let reserved {
                XCTAssertEqual(installed.archive?.id, reserved.archiveID)
                XCTAssertEqual(installed.archive?.file.id, reserved.recordID)
                XCTAssertEqual(installed.revision, reserved.candidateRevision)
            }
            let consumed = try await sourceFactsValue(handoffReadIntent(box)).get(); XCTAssertNil(consumed)
        }
    }

    // Catches trusting corrupt, transplanted or stale predecessor reservation bytes, or recapturing on those failures.
    func testInvalidNativeReservationRefusesRetryWithoutNewCapture() async throws {
        for mutation in ["corrupt", "preparation", "base"] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let repository = ArchiveHandoffRepository(box)
            let store = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: fixture.archive) })
            let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First"),
                         try await sourceFactsDocument(fixture, name: "second.txt", text: "Second")]
            defer { items.forEach { try? $0.discard() } }
            let id = UUID()
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
            do {
                try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                    previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
                XCTFail("Fixture must refuse candidate retention")
            } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .unavailable) }
            let changed = try await sourceFactsValue(handoffMutateIntent(box, mutation: mutation)); XCTAssertTrue(changed)
            let before = try await sourceFactsLoad(store)
            let retry = fixture.session(box)
            do {
                try await retry.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                    previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
                XCTFail("Invalid native reservation must fail closed")
            } catch let error as TelegramPendingUploadPersistenceError {
                XCTAssertEqual(error, mutation == "corrupt" ? .incompatibleData : .conflict)
            }
            let unchanged = try await sourceFactsLoad(retry); XCTAssertEqual(unchanged, before)
            XCTAssertEqual(try recordCount(fixture), 3)
        }
    }

    private func recordCount(_ fixture: SourceFactsTestArchive) throws -> Int {
        let rows = try fixture.database.execute("SELECT count(DISTINCT object) FROM \"\(fixture.database.schema)\".archive_file_events")
        return try XCTUnwrap(Int(try XCTUnwrap(rows.first?.first))) + fixture.localRecords().count
    }
}

@MainActor private final class ArchiveHandoffRepository: TelegramPendingUploadRepository {
    let accountID: Int64 = 1
    let base: TelegramPostboxPendingUploadRepository
    var failIntent: Bool?
    var refusedCandidate: TelegramPendingUploadDraft?
    var restoreBeforeRetention: TelegramPendingUploadDraft?
    var restoreBeforeInstallation: TelegramPendingUploadDraft?
    init(_ box: Postbox) { base = .init(postbox: box, accountID: 1) }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.load(chatID: chatID, completion: completion)
    }
    func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?, completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        base.save(draft, expectedRevision: expectedRevision, completion: completion)
    }
    func loadArchiveIntent(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.loadArchiveIntent(chatID: chatID, completion: completion)
    }
    func retainArchiveIntent(_ intent: TelegramPendingUploadArchiveIntent, chatID: Int64, admission: TelegramPendingUploadArchiveAdmission,
                             completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        if let committed = failIntent {
            failIntent = nil
            if committed {
                base.retainArchiveIntent(intent, chatID: chatID, admission: admission) { result in
                    if case .success = result { completion(.failure(.unavailable)) } else { completion(result) }
                }
            } else { completion(.failure(.unavailable)) }
        } else { base.retainArchiveIntent(intent, chatID: chatID, admission: admission, completion: completion) }
    }
    func loadArchiveCapture(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.loadArchiveCapture(chatID: chatID, completion: completion)
    }
    func retainArchiveCapture(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission,
                              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        if let original = restoreBeforeRetention {
            restoreBeforeRetention = nil
            restore(original) { [base] in
                base.retainArchiveCapture(draft, expectedRevision: expectedRevision, admission: admission, completion: completion)
            } completion: { completion($0) }
            return
        }
        if restoreBeforeInstallation != nil {
            base.retainArchiveCapture(draft, expectedRevision: expectedRevision, admission: admission, completion: completion)
        } else { refusedCandidate = draft; completion(.failure(.unavailable)) }
    }
    func installArchive(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission,
                        completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        if let original = restoreBeforeInstallation {
            restoreBeforeInstallation = nil
            restore(original) { [base] in
                base.installArchive(draft, expectedRevision: expectedRevision, admission: admission, completion: completion)
            } completion: { completion($0) }
        } else { base.installArchive(draft, expectedRevision: expectedRevision, admission: admission, completion: completion) }
    }
    private func restore(_ original: TelegramPendingUploadDraft, then write: @escaping @MainActor () -> Void,
                         completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        do {
            let changed = original.updating(captionInput: try TelegramComposerInput(formattedText: .init(text: "Later edit")),
                captionAboveMedia: original.captionAboveMedia, mediaSpoiler: original.mediaSpoiler, disposition: .prepared)
            base.save(changed, expectedRevision: original.revision) { [base] result in
                guard case .success = result else { completion(result); return }
                base.save(original, expectedRevision: changed.revision) { result in
                    guard case .success = result else { completion(result); return }
                    write()
                }
            }
        } catch { completion(.failure(.incompatibleData)) }
    }
}

private nonisolated func handoffReadIntent(_ box: Postbox) -> Signal<Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>, NoError> {
    box.transaction { telegramPendingUploadArchiveIntentRead(transaction: $0, accountID: 1, chatID: 42) }
}
private nonisolated func handoffMutateIntent(_ box: Postbox, mutation: String) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let key = telegramPendingUploadArchiveIntentKey(accountID: 1, chatID: 42)
        guard let entry = transaction.getPreferencesEntry(key: key) else { return false }
        if mutation == "corrupt" {
            var data = entry.data; data[data.count - 1] = 0
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data))
        } else if mutation == "preparation" {
            let marker = Data("Makosh.PendingUpload.ArchiveIntent.v1\n".utf8), offset = marker.count + 32
            guard var json = (try? JSONSerialization.jsonObject(with: entry.data.dropFirst(offset))) as? [String: Any] else { return false }
            json["preparationID"] = UUID().uuidString
            guard let bytes = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return false }
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: entry.data.prefix(offset) + bytes))
        } else {
            guard case let .success(current?) = telegramPendingUploadRead(transaction: transaction, accountID: 1, chatID: 42),
                  let changed = try? TelegramPendingUploadDraft(id: current.id, revision: current.revision, accountID: 1, chatID: 42,
                    title: current.title, captionInput: .init(formattedText: .init(text: "Same UUID, different bytes")),
                    originalDraft: current.originalDraft, replyTarget: current.replyTarget,
                    items: current.items, isGrouped: false, presentation: .file, captionRules: current.captionRules) else { return false }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let bytes = try? encoder.encode(changed) else { return false }
            transaction.setPreferencesEntry(key: telegramPendingUploadKey(accountID: 1, chatID: 42),
                value: PreferencesEntry(data: Data("Makosh.PendingUpload.JSON.v1\n".utf8) + bytes))
        }
        return true
    }
}
