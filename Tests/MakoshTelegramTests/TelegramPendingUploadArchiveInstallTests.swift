import XCTest
import Foundation
import MakoshCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadArchiveInstallTests: TelegramSourceFactsIntegrationTestCase {
    // Catches losing a successful ZIP capture when native pointer installation fails before commit.
    func testFailedNativeInstallRetainsExactCandidateAcrossEncryptedReopenWithoutRecapture() async throws {
        for (enabled, fault) in [(false, "install"), (true, "install"), (false, "retentionACK"), (true, "retentionACK")] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            var retained: PreparedArchive?, attempted: TelegramPendingUploadDraft?
            weak var previous: Postbox?
            do {
                let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
                let setup = try await preparedArchive(fixture, box: box); retained = setup
                let repository = ArchiveInstallGateRepository(box)
                repository.failNextInstallBeforeCommit = fault == "install"
                repository.failNextCaptureAcknowledgement = fault == "retentionACK"
                do { _ = try await install(session(fixture, repository: repository), setup: setup); XCTFail("Native refusal must be reported") }
                catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .unavailable) }
                attempted = try XCTUnwrap(repository.refusedCandidate)
                let unchanged = try await sourceFactsLoad(fixture.session(box))
                XCTAssertEqual(unchanged, setup.draft)
            }
            let setup = try XCTUnwrap(retained)
            defer { setup.discard() }
            for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previous)
            let local = try fixture.localRecords(), events = try fileEvents(fixture), stages = try ownedDirectories()
            let box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
            let recovered = try await store.loadArchiveCapture(chatID: 42)
            let receipt = try XCTUnwrap(recovered)
            let descriptor = try XCTUnwrap(receipt.candidate.archive)
            XCTAssertEqual(receipt.expectedRevision, setup.draft.revision)
            if !enabled {
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
                let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: descriptor.file.objectKey)
                XCTAssertNil(object)
            }
            let installed = try await store.installArchive(preparationID: receipt.candidate.id,
                expectedRevision: receipt.expectedRevision, archive: descriptor,
                target: setup.target, admission: token(setup.draft))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(installed), try encoder.encode(XCTUnwrap(attempted)),
                "A successful capture must retain its exact installation candidate, not mint another revision after reopen")
            let consumed = try await store.loadArchiveCapture(chatID: 42); XCTAssertNil(consumed)
            XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
            XCTAssertEqual(try ownedDirectories(), stages)
        }
    }

    // Catches recapturing or refusing the committed ZIP when its ACK was lost and the encrypted Postbox reopened.
    func testLostAcknowledgementReplaysExactInstallationAfterEncryptedReopenWithoutRecapture() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            var retained: PreparedArchive?, committed: TelegramPendingUploadDraft?
            weak var previous: Postbox?
            do {
                let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
                let setup = try await preparedArchive(fixture, box: box); retained = setup
                let repository = ArchiveInstallGateRepository(box)
                repository.failNextAcknowledgement = true
                do { _ = try await install(session(fixture, repository: repository), setup: setup); XCTFail("Lost ACK must be reported") }
                catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .unavailable) }
                committed = try await sourceFactsLoad(fixture.session(box))
                XCTAssertEqual(committed?.schemaVersion, 18)
            }
            let setup = try XCTUnwrap(retained)
            defer { setup.discard() }
            for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previous)
            let local = try fixture.localRecords(), events = try fileEvents(fixture), stages = try ownedDirectories()
            let box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
            do {
                let replayed = try await install(store, setup: setup)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                XCTAssertEqual(try encoder.encode(replayed), try encoder.encode(XCTUnwrap(committed)))
            } catch { XCTFail("Fresh session must confirm its exact committed installation: \(error)") }
            let pointer = try await sourceFactsLoad(store)
            XCTAssertEqual(pointer, committed)
            XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
            XCTAssertEqual(try ownedDirectories(), stages)
        }
    }

    // Catches acknowledging a later edit, including A→B→A, merely because the retained ZIP still matches.
    func testFreshSessionReplayRefusesLaterCaptionRevisionsAndStartedSubmission() async throws {
        for mutation in ["caption", "roundTrip", "started"] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            let setup = try await preparedArchive(fixture, box: box)
            defer { setup.discard() }
            _ = try await install(fixture.session(box), setup: setup)
            let editor = fixture.session(box)
            let changed = try TelegramComposerInput(formattedText: .init(text: "Later caption"))
            try await editor.save(preparationID: setup.draft.id, chatID: 42, captionInput: changed, disposition: .prepared)
            if mutation == "roundTrip" || mutation == "started" {
                try await editor.save(preparationID: setup.draft.id, chatID: 42, captionInput: setup.draft.captionInput,
                    disposition: mutation == "started" ? .submissionStarted : .prepared)
            }
            let newer = try await sourceFactsLoad(editor), stages = try ownedDirectories()
            let local = try fixture.localRecords(), events = try fileEvents(fixture)
            do { _ = try await install(fixture.session(box), setup: setup); XCTFail("Replay accepted a later \(mutation) revision") }
            catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
            let retained = try await sourceFactsLoad(editor)
            XCTAssertEqual(retained, newer)
            XCTAssertEqual(try ownedDirectories(), stages)
            XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
        }
    }

    // Catches replacing canonical/raw editor state, recapturing, or promoting OFF records during installation/reopen.
    func testInstallPreservesAuthenticatedBundleAndRawEditorAcrossEncryptedReopenWithoutRecapture() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            var installed: TelegramPendingUploadDraft?, bytes: [Data] = [], rawBytes: [Data?] = [], zipBytes = Data()
            var local: [String] = [], events: [[String]] = []
            weak var previous: Postbox?
            do {
                let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
                let setup = try await preparedArchive(fixture, box: box, visual: true)
                defer { setup.discard() }
                bytes = try setup.items.map { try Data(contentsOf: $0.file.url) }
                rawBytes = try setup.items.map { try $0.originalFile.map { try Data(contentsOf: $0.url) } }
                zipBytes = try Data(contentsOf: setup.zip.file.url)
                local = try fixture.localRecords(); events = try fileEvents(fixture)
                setup.discard()
                for name in ["photo.jpg", "second.jpg"] {
                    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(name))
                }
                let stages = try ownedDirectories(), store = fixture.session(box)
                let result: TelegramPendingUploadDraft
                let relabeledTarget = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Later chat label", replySource: setup.target.replySource)
                do { result = try await install(store, setup: setup, target: relabeledTarget) }
                catch { return XCTFail("An already authenticated archive must install: \(error)") }
                XCTAssertEqual(result.schemaVersion, 18); XCTAssertEqual(result.presentation, .archive)
                XCTAssertEqual(result.disposition, .prepared); XCTAssertNotEqual(result.revision, setup.draft.revision)
                XCTAssertEqual(result.id, setup.draft.id); XCTAssertEqual(result.title, setup.draft.title)
                XCTAssertEqual(result.items, setup.draft.items); XCTAssertEqual(result.archive, setup.descriptor)
                XCTAssertEqual(result.captionInput, setup.draft.captionInput)
                XCTAssertEqual(result.captionInput.formattedText.text, "  😀 Bold  \u{FFFC}")
                XCTAssertEqual(result.originalDraft, setup.draft.originalDraft); XCTAssertEqual(result.replyTarget, setup.draft.replyTarget)
                XCTAssertFalse(result.isGrouped); XCTAssertFalse(result.captionAboveMedia); XCTAssertFalse(result.mediaSpoiler)
                XCTAssertEqual(try ownedDirectories(), stages, "Authentication stages must be discarded before acknowledgement")
                let pointer = try await sourceFactsLoad(store); XCTAssertEqual(pointer, result)
                XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
                installed = result
            }
            for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previous)
            let box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
            let pointer = try await sourceFactsLoad(store)
            XCTAssertEqual(pointer, installed)
            let recovered = try await store.restoreBundle(draft: pointer)
            defer { try? recovered.discard() }
            XCTAssertEqual(try recovered.items.map { try Data(contentsOf: $0.file.url) }, bytes)
            XCTAssertEqual(try recovered.items.map { try $0.originalFile.map { try Data(contentsOf: $0.url) } }, rawBytes)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovered.archive?.file.url)), zipBytes)
            XCTAssertEqual(recovered.items.map(\.sourceFacts), pointer.items.map(\.sourceFacts))
            XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
            let records = pointer.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) } + [try XCTUnwrap(pointer.archive?.file)]
            XCTAssertTrue(records.allSatisfy { $0.state == (enabled ? .stored : .local) })
            if !enabled {
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
                for record in records {
                    let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                    XCTAssertNil(object)
                }
                XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
            }
        }
    }

    // Catches treating a syntactically valid descriptor as authenticated without exporting/inspecting its ZIP.
    func testForgedRecordAndMemberNamesRefuseWithoutPointerWriteOrLeakedStages() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let setup = try await preparedArchive(fixture, box: box)
            defer { setup.discard() }
            var recordJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup.descriptor.file)) as? [String: Any])
            recordJSON["capturedAt"] = setup.descriptor.file.capturedAt.timeIntervalSinceReferenceDate + 1
            let changedRecord = try JSONDecoder().decode(ArchiveFileRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON))
            recordJSON["id"] = UUID().uuidString
            let fabricatedRecord = try JSONDecoder().decode(ArchiveFileRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON))
            let changedNames = TelegramPendingUploadArchive(id: setup.descriptor.id, file: setup.descriptor.file,
                members: [.init(itemID: setup.items[0].id, entryName: "different.txt"), setup.descriptor.members[1]])
            let changedMetadata = TelegramPendingUploadArchive(id: setup.descriptor.id, file: changedRecord, members: setup.descriptor.members)
            let fabricated = TelegramPendingUploadArchive(id: setup.descriptor.id, file: fabricatedRecord, members: setup.descriptor.members)
            let stages = try ownedDirectories(), local = try fixture.localRecords(), events = try fileEvents(fixture)
            for descriptor in [changedNames, changedMetadata, fabricated] {
                let candidate = try candidate(setup.draft, descriptor: descriptor)
                XCTAssertTrue(candidate.isValid, "Shape validation must not stand in for authenticated export")
                do { _ = try await install(fixture.session(box), setup: setup, descriptor: descriptor); XCTFail("Forged archive installed") }
                catch { }
                let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, setup.draft)
                XCTAssertEqual(try ownedDirectories(), stages)
                XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
            }
        }
    }

    // Catches installing an archive over a newer caption, another preparation/account/chat/reply, or a terminal pointer.
    func testStaleRevisionScopeReplyAndDispositionRefuseWithoutReplacingPointer() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let setup = try await preparedArchive(fixture, box: box)
        defer { setup.discard() }
        let store = fixture.session(box), local = try fixture.localRecords(), events = try fileEvents(fixture)
        let wrongTargets: [TelegramUploadTarget] = [
            .init(accountID: 2, chatID: 42, title: "Other account"),
            .init(accountID: 1, chatID: 43, title: "Other chat"),
            .init(accountID: 1, chatID: 42, title: "Reply removed")]
        for target in wrongTargets {
            do { _ = try await install(store, setup: setup, target: target); XCTFail("Different target installed") }
            catch { }
        }
        do { _ = try await install(store, setup: setup, preparationID: UUID()); XCTFail("Different preparation installed") }
        catch { }
        do { _ = try await install(store, setup: setup, expectedRevision: UUID()); XCTFail("Stale revision installed") }
        catch { }
        let updatedCaption = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Newer editor"))
        try await store.save(preparationID: setup.draft.id, chatID: 42, captionInput: updatedCaption, disposition: .prepared)
        let newer = try await sourceFactsLoad(store)
        do { _ = try await install(store, setup: setup); XCTFail("Old revision overwrote newer raw caption") }
        catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let retained = try await sourceFactsLoad(store); XCTAssertEqual(retained, newer)
        let dispositions: [TelegramPendingUploadDisposition] = [.submissionStarted, .cancelled]
        for disposition in dispositions {
            try await store.save(preparationID: setup.draft.id, chatID: 42, captionInput: updatedCaption, disposition: disposition)
            let terminal = try await sourceFactsLoad(store)
            do { _ = try await install(store, setup: setup, expectedRevision: terminal.revision); XCTFail("Non-prepared pointer installed") }
            catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
            let pointer = try await sourceFactsLoad(store); XCTAssertEqual(pointer, terminal)
        }
        XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
    }

    // Catches accepting schema14 just because its durable source facts can be structurally converted to schema16.
    func testLegacySourceFactsPointerIsNotUpgradedByArchiveInstall() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let setup = try await preparedArchive(fixture, box: box)
        defer { setup.discard() }
        let old = try TelegramPendingUploadDraft(id: setup.draft.id, accountID: 1, chatID: 42, title: setup.draft.title,
            captionInput: setup.draft.captionInput, originalDraft: setup.draft.originalDraft, replyTarget: setup.draft.replyTarget,
            items: setup.draft.items, isGrouped: false, presentation: .file, captionRules: .legacy)
        XCTAssertEqual(old.schemaVersion, 14); XCTAssertTrue(old.isValid)
        try (await sourceFactsValue(archiveInstallTestWrite(box, draft: old, expectedRevision: setup.draft.revision))).get()
        do { _ = try await install(fixture.session(box), setup: setup, expectedRevision: old.revision); XCTFail("Legacy caption meaning upgraded") }
        catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, old)
    }

    // Catches generic serial's intentionally detached cancellation behavior escaping into this generation-bound operation.
    func testPreCancelledCallerAndInactiveAdmissionRefuseWithoutExportsOrWrites() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let setup = try await preparedArchive(fixture, box: box)
        defer { setup.discard() }
        let store = fixture.session(box), stages = try ownedDirectories()
        let local = try fixture.localRecords(), events = try fileEvents(fixture)
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.install(store, setup: setup)
        }
        do { _ = try await operation.value; XCTFail("Pre-cancelled caller installed") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        let admission = token(setup.draft); admission.cancel()
        do { _ = try await install(store, setup: setup, admission: admission); XCTFail("Inactive generation installed") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        let pointer = try await sourceFactsLoad(store); XCTAssertEqual(pointer, setup.draft)
        XCTAssertEqual(try ownedDirectories(), stages)
        XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
    }

    // Catches failing to invalidate admission when caller cancellation arrives while serial is suspended in repository load.
    func testCancellationDuringReadCannotPublishAfterLoadCompletes() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let setup = try await preparedArchive(fixture, box: box)
        defer { setup.discard() }
        let repository = ArchiveInstallGateRepository(box), store = session(fixture, repository: repository)
        repository.holdNextLoad = true
        let operation = Task { try await self.install(store, setup: setup) }
        for _ in 0..<100 where repository.heldLoad == nil { try await Task.sleep(for: .milliseconds(5)) }
        guard repository.heldLoad != nil else {
            operation.cancel(); _ = await operation.result
            return XCTFail("Install must read its authoritative pointer before publishing")
        }
        operation.cancel(); repository.releaseLoad()
        do { _ = try await operation.value; XCTFail("Cancelled suspended operation installed") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        let pointer = try await sourceFactsLoad(fixture.session(box)); XCTAssertEqual(pointer, setup.draft)
    }

    // Catches using a read-time revision after a second session edited the real encrypted pointer during authentication.
    func testTwoSessionsCASRefusesNewerPointerAndDiscardsAuthenticationBundleBeforeWrite() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let setup = try await preparedArchive(fixture, box: box)
        defer { setup.discard() }
        let repository = ArchiveInstallGateRepository(box), store = session(fixture, repository: repository)
        let stages = try ownedDirectories(), local = try fixture.localRecords(), events = try fileEvents(fixture)
        repository.holdNextInstall = true
        let operation = Task { try await self.install(store, setup: setup) }
        for _ in 0..<200 where repository.heldInstall == nil { try await Task.sleep(for: .milliseconds(5)) }
        guard repository.heldInstall != nil else {
            operation.cancel(); _ = await operation.result
            return XCTFail("Authenticated archive must use the guarded repository CAS")
        }
        XCTAssertEqual(try ownedDirectories(), stages, "Discard temporary bundle before entering native CAS")
        let second = fixture.session(box), caption = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Second session wins"))
        try await second.save(preparationID: setup.draft.id, chatID: 42, captionInput: caption, disposition: .prepared)
        let newer = try await sourceFactsLoad(second)
        repository.releaseInstall()
        do { _ = try await operation.value; XCTFail("Stale CAS replaced second session's caption") }
        catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let retained = try await sourceFactsLoad(second); XCTAssertEqual(retained, newer)
        XCTAssertNil(retained.archive); XCTAssertEqual(retained.captionInput.formattedText.text, "Second session wins")
        XCTAssertEqual(try ownedDirectories(), stages)
        XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
    }

    // Catches reporting cancellation after the native CAS already committed and its success ACK is merely delayed.
    func testCancellationAfterNativeCommitReturnsTheCommittedCandidate() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let setup = try await preparedArchive(fixture, box: box)
        defer { setup.discard() }
        let repository = ArchiveInstallGateRepository(box), store = session(fixture, repository: repository)
        repository.holdNextAcknowledgement = true
        let operation = Task { try await self.install(store, setup: setup) }
        for _ in 0..<200 where repository.heldAcknowledgement == nil { try await Task.sleep(for: .milliseconds(5)) }
        guard repository.heldAcknowledgement != nil else {
            operation.cancel(); _ = await operation.result
            return XCTFail("Successful native installation must await its completion")
        }
        let committed = try await sourceFactsLoad(fixture.session(box))
        XCTAssertEqual(committed.schemaVersion, 18); XCTAssertEqual(committed.archive, setup.descriptor)
        operation.cancel(); repository.releaseAcknowledgement()
        do {
            let returned = try await operation.value
            XCTAssertEqual(returned, committed)
        } catch { XCTFail("Cancellation after committed CAS must not hide its success: \(error)") }
    }

    private struct PreparedArchive {
        let items: [TelegramUploadBatchItem]
        let draft: TelegramPendingUploadDraft
        let zip: TelegramUploadArchiveIO.Archive
        let descriptor: TelegramPendingUploadArchive
        let target: TelegramUploadTarget
        func discard() { items.forEach { try? $0.discard() }; try? TelegramUploadFileIO.discard(zip.file) }
    }

    private func preparedArchive(_ fixture: SourceFactsTestArchive, box: Postbox, visual: Bool = false) async throws -> PreparedArchive {
        let items: [TelegramUploadBatchItem]
        if visual { items = [try await sourceFactsPhoto(fixture), try await sourceFactsPhoto(fixture, name: "second.jpg")] }
        else { items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "Synthetic first source"),
                        try await sourceFactsDocument(fixture, name: "second.txt", text: "Synthetic second source")] }
        do {
            let reply = TelegramMessageActionSource(accountID: 1, chatID: 42, peerID: 42, namespace: 0, messageID: 7,
                fingerprint: "synthetic-reply", text: "Synthetic reply", canReply: true, canEdit: false,
                canForward: false, canDeleteLocally: false, canDeleteForEveryone: false)
            let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Original preparation title", replySource: reply)
            let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "  😀 Bold  \u{FFFC}",
                entities: [.init(offset: 2, length: 2, kind: .bold)]), selection: .init(location: 2, length: 2))
            let original = TelegramComposerDraft(accountID: 1, chatID: 42, input: input, replyTarget: .init(source: reply))
            let id = UUID(), store = fixture.session(box)
            try await store.prepare(preparationID: id, items: items, isGrouped: visual, presentation: visual ? .media : .file,
                target: target, captionInput: input, captionAboveMedia: visual, mediaSpoiler: visual, originalDraft: original)
            let draft = try await sourceFactsLoad(store)
            XCTAssertEqual(draft.schemaVersion, 17); XCTAssertTrue(draft.isValid)
            let sources = items.map { TelegramUploadArchiveIO.Source(itemID: $0.id, file: $0.rawSource) }
            let zip = try await TelegramUploadArchiveIO.prepare(sources)
            do {
                let record = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(zip, sources: sources,
                    archiveID: zip.file.id, accountID: 1, chatID: 42, preparationID: id)
                let descriptor = TelegramPendingUploadArchive(id: zip.file.id, file: record,
                    members: zip.members.map { .init(itemID: $0.itemID, entryName: $0.entryName) })
                return .init(items: items, draft: draft, zip: zip, descriptor: descriptor, target: target)
            } catch { try? TelegramUploadFileIO.discard(zip.file); throw error }
        } catch { items.forEach { try? $0.discard() }; throw error }
    }

    private func token(_ draft: TelegramPendingUploadDraft, preparationID: UUID? = nil, revision: UUID? = nil,
                       target: TelegramUploadTarget? = nil) -> TelegramPendingUploadArchiveAdmission {
        .init(accountID: target?.accountID ?? draft.accountID, chatID: target?.chatID ?? draft.chatID,
            preparationID: preparationID ?? draft.id, expectedRevision: revision ?? draft.revision, generation: UUID())
    }

    private func install(_ store: any TelegramUploadRecoveryStore, setup: PreparedArchive,
                         descriptor: TelegramPendingUploadArchive? = nil, preparationID: UUID? = nil,
                         expectedRevision: UUID? = nil, target: TelegramUploadTarget? = nil,
                         admission: TelegramPendingUploadArchiveAdmission? = nil) async throws -> TelegramPendingUploadDraft {
        try await store.installArchive(preparationID: preparationID ?? setup.draft.id,
            expectedRevision: expectedRevision ?? setup.draft.revision, archive: descriptor ?? setup.descriptor,
            target: target ?? setup.target,
            admission: admission ?? token(setup.draft, preparationID: preparationID, revision: expectedRevision, target: target))
    }

    private func candidate(_ draft: TelegramPendingUploadDraft, descriptor: TelegramPendingUploadArchive) throws -> TelegramPendingUploadDraft {
        try .init(id: draft.id, accountID: draft.accountID, chatID: draft.chatID, title: draft.title,
            captionInput: draft.captionInput, originalDraft: draft.originalDraft, replyTarget: draft.replyTarget,
            items: draft.items, isGrouped: false, presentation: .archive, archive: descriptor)
    }

    private func session(_ fixture: SourceFactsTestArchive, repository: any TelegramPendingUploadRepository) -> TelegramPendingUploadSession {
        .init(repository: repository, files: { TelegramPendingUploadFiles(repository: fixture.archive) })
    }
    private func ownedDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("makosh-upload-") }.map(\.path))
    }
    private func fileEvents(_ fixture: SourceFactsTestArchive) throws -> [[String]] {
        try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events")
    }
}

// Pause only MainActor delivery/dispatch; actual storage and final CAS remain the real native repository.
@MainActor private final class ArchiveInstallGateRepository: TelegramPendingUploadRepository {
    let accountID: Int64 = 1
    let base: TelegramPostboxPendingUploadRepository
    var holdNextLoad = false, holdNextInstall = false, holdNextAcknowledgement = false, failNextAcknowledgement = false
    var failNextInstallBeforeCommit = false
    var failNextCaptureAcknowledgement = false
    var refusedCandidate: TelegramPendingUploadDraft?
    var heldLoad: (Int64, @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void)?
    var heldInstall: (TelegramPendingUploadDraft, UUID, TelegramPendingUploadArchiveAdmission,
                      @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void)?
    var heldAcknowledgement: (@MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void,
                              Result<Void, TelegramPendingUploadPersistenceError>)?
    private var loadOperation: Disposable?
    init(_ box: Postbox) { base = .init(postbox: box, accountID: 1) }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        if holdNextLoad { holdNextLoad = false; heldLoad = (chatID, completion); return EmptyDisposable }
        return base.load(chatID: chatID, completion: completion)
    }
    func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?,
              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        base.save(draft, expectedRevision: expectedRevision, completion: completion)
    }
    func loadArchiveIntent(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.loadArchiveIntent(chatID: chatID, completion: completion)
    }
    func retainArchiveIntent(_ intent: TelegramPendingUploadArchiveIntent, chatID: Int64, admission: TelegramPendingUploadArchiveAdmission,
                             completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        base.retainArchiveIntent(intent, chatID: chatID, admission: admission, completion: completion)
    }
    func loadArchiveCapture(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.loadArchiveCapture(chatID: chatID, completion: completion)
    }
    func retainArchiveCapture(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                              admission: TelegramPendingUploadArchiveAdmission,
                              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        if failNextCaptureAcknowledgement {
            failNextCaptureAcknowledgement = false; refusedCandidate = draft
            base.retainArchiveCapture(draft, expectedRevision: expectedRevision, admission: admission) { result in
                if case .success = result { completion(.failure(.unavailable)) }
                else { completion(result) }
            }
        } else {
            base.retainArchiveCapture(draft, expectedRevision: expectedRevision, admission: admission, completion: completion)
        }
    }
    func installArchive(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                        admission: TelegramPendingUploadArchiveAdmission,
                        completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        if holdNextInstall { holdNextInstall = false; heldInstall = (draft, expectedRevision, admission, completion); return }
        if failNextInstallBeforeCommit {
            failNextInstallBeforeCommit = false; refusedCandidate = draft
            completion(.failure(.unavailable)); return
        }
        if failNextAcknowledgement {
            failNextAcknowledgement = false
            base.installArchive(draft, expectedRevision: expectedRevision, admission: admission) { result in
                if case .success = result { completion(.failure(.unavailable)) }
                else { completion(result) }
            }
            return
        }
        if holdNextAcknowledgement {
            holdNextAcknowledgement = false
            base.installArchive(draft, expectedRevision: expectedRevision, admission: admission) { result in
                self.heldAcknowledgement = (completion, result)
            }
            return
        }
        base.installArchive(draft, expectedRevision: expectedRevision, admission: admission, completion: completion)
    }
    func releaseLoad() {
        guard let heldLoad else { return }; self.heldLoad = nil
        loadOperation = base.load(chatID: heldLoad.0, completion: heldLoad.1)
    }
    func releaseInstall() {
        guard let heldInstall else { return }; self.heldInstall = nil
        base.installArchive(heldInstall.0, expectedRevision: heldInstall.1, admission: heldInstall.2, completion: heldInstall.3)
    }
    func releaseAcknowledgement() {
        guard let heldAcknowledgement else { return }; self.heldAcknowledgement = nil
        heldAcknowledgement.0(heldAcknowledgement.1)
    }
}

private nonisolated func archiveInstallTestWrite(_ box: Postbox, draft: TelegramPendingUploadDraft, expectedRevision: UUID)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    box.transaction { telegramPendingUploadWrite(transaction: $0, accountID: 1, draft: draft, expectedRevision: expectedRevision) }
}
