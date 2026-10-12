import XCTest
import Foundation
@testable import MakoshTelegram
@testable import MakoshApp

@MainActor final class TelegramUploadAppendControllerTests: TelegramSourceFactsIntegrationTestCase {
    // Catches restaging/deleting the existing set or changing its frozen caption policy while appending.
    func testAppendPublishesOnlyAfterCommitAndRetainsOriginalResourcesUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let source = fixture.root.appendingPathComponent("old.txt"), addition = fixture.root.appendingPathComponent("new.txt")
            try Data("old".utf8).write(to: source); try Data("new".utf8).write(to: addition)
            let store = fixture.session(box), controller = TelegramUploadController()
            controller.bind(provider: AppendControllerProvider(), recoveryStore: store, requiresRecovery: true)
            let input = try TelegramComposerInput(formattedText: .init(text: "**Append** 😀 #media"))
            controller.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false, target: fixture.target,
                captionInput: input, captionPolicy: try .init(maximumUTF16Count: 2048))
            try await ready(controller)
            let old = try await sourceFactsLoad(store), context = try XCTUnwrap(controller.preparationContextID)
            let revision = controller.itemsRevision
            try FileManager.default.removeItem(at: source)
            let accepted = controller.append(sources: [.init(source: addition, mode: .file)], contextID: context, revision: revision)
            XCTAssertTrue(accepted)
            guard accepted else { continue }
            XCTAssertEqual(controller.items.map(\.id), old.items.map(\.id)); XCTAssertFalse(controller.canSend)
            XCTAssertFalse(controller.append(sources: [.init(source: addition, mode: .file)], contextID: context, revision: revision))
            try await ready(controller)
            let updated = try await sourceFactsLoad(store)
            XCTAssertEqual(updated.items.count, 2); XCTAssertEqual(Array(updated.items.prefix(old.items.count)), old.items)
            XCTAssertEqual(controller.items.map(\.id), updated.items.map(\.id))
            XCTAssertEqual(updated.captionInput, input); XCTAssertEqual(updated.captionPolicy?.maximumUTF16Count, 2048)
            XCTAssertEqual(controller.captionInput, input); XCTAssertTrue(controller.canSend)
            XCTAssertEqual(controller.preparationContextID, context); XCTAssertNotEqual(controller.itemsRevision, revision)
            XCTAssertEqual(try Data(contentsOf: controller.items[0].file.url), Data("old".utf8))
            XCTAssertEqual(try Data(contentsOf: controller.items[1].file.url), Data("new".utf8))
            XCTAssertFalse(controller.append(sources: [.init(source: addition, mode: .file)], contextID: context, revision: controller.itemsRevision))
            XCTAssertFalse(controller.append(sources: [.init(source: URL(fileURLWithPath: "/synthetic/not-read"), mode: .file)],
                contextID: context, revision: revision))
            let removedID = try XCTUnwrap(controller.items.last?.id)
            XCTAssertTrue(controller.removeItem(id: removedID, contextID: context, revision: controller.itemsRevision))
            try await ready(controller)
            let readded = controller.append(sources: [.init(source: addition, mode: .file)], contextID: context, revision: controller.itemsRevision)
            XCTAssertTrue(readded)
            if readded { try await ready(controller); XCTAssertEqual(controller.items.count, 2) }
            if !enabled {
                let before = try fixture.localRecords()
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                _ = try await fixture.archive.resume()
                XCTAssertEqual(try fixture.localRecords(), before)
            }
        }
    }

    // Catches dropping a retained Archive or replacing its old members with only the new files.
    func testAppendRebuildsAnActiveZIPWithoutLosingThePreviousPreparationOnStagingFailure() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let sources = ["a.txt", "b.txt", "c.txt"].map { fixture.root.appendingPathComponent($0) }
        for source in sources { try Data(source.lastPathComponent.utf8).write(to: source) }
        let store = fixture.session(box), controller = TelegramUploadController()
        controller.bind(provider: AppendControllerProvider(), recoveryStore: store, requiresRecovery: true)
        controller.prepare(sources: sources.prefix(2).map { .init(source: $0, mode: .file) }, isGrouped: false,
            target: fixture.target, captionInput: .empty, captionPolicy: try .init(maximumUTF16Count: 1024))
        try await ready(controller)
        let context = try XCTUnwrap(controller.preparationContextID)
        XCTAssertTrue(controller.updatePresentation(.archive, contextID: context, revision: controller.itemsRevision))
        try await ready(controller)
        let old = try await sourceFactsLoad(store)
        let broken = controller.append(sources: [.init(source: sources[2], mode: .file),
            .init(source: URL(fileURLWithPath: "/synthetic/not-opened"), mode: .file)], contextID: context, revision: controller.itemsRevision)
        XCTAssertTrue(broken)
        guard broken else { return }
        try await ready(controller, permitsError: true)
        let unchanged = try await sourceFactsLoad(store)
        XCTAssertEqual(unchanged, old); XCTAssertEqual(controller.items.map(\.id), old.items.map(\.id))
        XCTAssertEqual(controller.presentation, .archive); XCTAssertTrue(controller.canSend)
        let accepted = controller.append(sources: [.init(source: sources[2], mode: .file)], contextID: context, revision: controller.itemsRevision)
        XCTAssertTrue(accepted)
        guard accepted else { return }
        try await ready(controller)
        let updated = try await sourceFactsLoad(store)
        XCTAssertEqual(updated.items.count, 3); XCTAssertEqual(updated.presentation, .archive)
        XCTAssertEqual(updated.archive?.members.map(\.itemID), updated.items.map(\.id))
        XCTAssertEqual(controller.items.map(\.id), updated.items.map(\.id)); XCTAssertEqual(controller.presentedItems.count, 1)
        XCTAssertTrue(controller.canSend); XCTAssertTrue(controller.messageIDs.isEmpty)
    }

    // Catches recapturing after an install ACK loss, including after the picker path disappears.
    func testLostAppendACKRetriesOnlyTheExactCandidateWithoutSending() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let store = AppendACKLossStore(base: fixture.session(box)), controller = TelegramUploadController()
        let old = fixture.root.appendingPathComponent("old.txt"), new = fixture.root.appendingPathComponent("new.txt")
        try Data("old".utf8).write(to: old); try Data("new".utf8).write(to: new)
        controller.bind(provider: AppendControllerProvider(), recoveryStore: store, requiresRecovery: true)
        controller.prepare(sources: [.init(source: old, mode: .file)], isGrouped: false, target: fixture.target,
            captionInput: .empty, captionPolicy: try .init(maximumUTF16Count: 1024))
        try await ready(controller)
        let context = try XCTUnwrap(controller.preparationContextID), before = controller.items.map(\.id)
        guard controller.append(sources: [.init(source: new, mode: .file)], contextID: context, revision: controller.itemsRevision) else {
            XCTFail("Append was rejected"); return
        }
        for _ in 0..<1000 where controller.phase == .preparing || controller.isRecoveryBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready); XCTAssertFalse(controller.canSend); XCTAssertTrue(controller.canRetryRecovery)
        XCTAssertEqual(controller.items.map(\.id), before)
        XCTAssertFalse(controller.updateCaptionInput(try .init(formattedText: .init(text: "late edit")), contextID: controller.captionContextID))
        let installed = try await sourceFactsLoad(store.base)
        XCTAssertEqual(installed.items.count, 2)
        try FileManager.default.removeItem(at: new)
        controller.retryRecovery(); try await ready(controller)
        XCTAssertEqual(store.captureCalls, 1); XCTAssertEqual(store.installCalls, 2)
        let retried = try await sourceFactsLoad(store.base)
        XCTAssertEqual(try telegramUploadAppendBytes(retried), try telegramUploadAppendBytes(installed))
        XCTAssertEqual(controller.items.map(\.id), installed.items.map(\.id)); XCTAssertTrue(controller.canSend)
        XCTAssertTrue(controller.messageIDs.isEmpty)
    }

    // Catches reading a stale drag or routing preview File additions through Media.
    func testPreviewDropRevalidatesAccountPreparationAndCaptionBeforeReadingAnyFile() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let store = fixture.session(box), controller = TelegramUploadController()
        let old = fixture.root.appendingPathComponent("old.txt"), new = fixture.root.appendingPathComponent("new.png")
        try Data("old".utf8).write(to: old); try writeUploadVideoCoverFixture(new)
        controller.bind(provider: AppendControllerProvider(), recoveryStore: store, requiresRecovery: true)
        controller.prepare(sources: [.init(source: old, mode: .file)], isGrouped: false, target: fixture.target,
            captionInput: .empty, captionPolicy: try .init(maximumUTF16Count: 1024))
        try await ready(controller)
        let account = UUID(), capture = try XCTUnwrap(TelegramUploadAppendDropCapture(upload: controller, contextID: account))
        let missing = URL(fileURLWithPath: "/synthetic/not-read")
        XCTAssertFalse(capture.prepare(urls: [missing], upload: controller, currentContextID: UUID(), photoSize: .standard))
        XCTAssertFalse(capture.prepare(urls: [new, URL(string: "file://other-host/not-read")!], upload: controller,
            currentContextID: account, photoSize: .standard))
        XCTAssertTrue(controller.updateCaptionInput(try .init(formattedText: .init(text: "new caption")), contextID: controller.captionContextID))
        XCTAssertFalse(capture.prepare(urls: [missing], upload: controller, currentContextID: account, photoSize: .standard))
        let fresh = try XCTUnwrap(TelegramUploadAppendDropCapture(upload: controller, contextID: account))
        let accepted = fresh.prepare(urls: [new, new], upload: controller, currentContextID: account, photoSize: .standard)
        XCTAssertTrue(accepted); guard accepted else { return }
        try await ready(controller)
        XCTAssertEqual(controller.items.count, 2); XCTAssertEqual(controller.presentation, .file)
        XCTAssertEqual(controller.presentedItems.last?.file.name, "new.png"); XCTAssertEqual(controller.presentedItems.last?.file.mode, .file)
        XCTAssertTrue(controller.messageIDs.isEmpty)
    }

    private func ready(_ controller: TelegramUploadController, permitsError: Bool = false) async throws {
        for _ in 0..<1000 where controller.phase == .preparing || controller.isRecoveryBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.phase, .ready); XCTAssertFalse(controller.isRecoveryBusy)
        XCTAssertNil(controller.recoveryStatus)
        if !permitsError { XCTAssertNil(controller.error) }
    }
}

@MainActor private final class AppendControllerProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Append must never send"); return AppendControllerLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Append must never send"); return AppendControllerLease()
    }
}
@MainActor private final class AppendControllerLease: TelegramUploadLease { func stop() {} }

@MainActor private final class AppendACKLossStore: TelegramUploadRecoveryStore {
    let base: TelegramPendingUploadSession
    var captureCalls = 0, installCalls = 0
    var accountID: Int64 { base.accountID }
    init(base: TelegramPendingUploadSession) { self.base = base }
    func load(chatID: Int64) async throws -> TelegramPendingUploadDraft? { try await base.load(chatID: chatID) }
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, presentation: TelegramUploadPresentation,
                 target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
                 mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?, captionPolicy: TelegramUploadCaptionPolicy?) async throws {
        try await base.prepare(preparationID: preparationID, items: items, isGrouped: isGrouped, presentation: presentation,
            target: target, captionInput: captionInput, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler,
            originalDraft: originalDraft, captionPolicy: captionPolicy)
    }
    func captureAppend(snapshot: TelegramPendingUploadDraft, additions: [TelegramUploadBatchItem], target: TelegramUploadTarget) async throws -> TelegramUploadAppendCapture {
        captureCalls += 1; return try await base.captureAppend(snapshot: snapshot, additions: additions, target: target)
    }
    func installAppend(_ capture: TelegramUploadAppendCapture, target: TelegramUploadTarget) async throws -> TelegramPendingUploadDraft {
        installCalls += 1
        let result = try await base.installAppend(capture, target: target)
        if installCalls == 1 { throw TelegramPendingUploadPersistenceError.conflict }
        return result
    }
    func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
              mediaSpoiler: Bool, disposition: TelegramPendingUploadDisposition) async throws {
        try await base.save(preparationID: preparationID, chatID: chatID, captionInput: captionInput,
            captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler, disposition: disposition)
    }
    func restoreBundle(draft: TelegramPendingUploadDraft) async throws -> TelegramRecoveredUploadBundle { try await base.restoreBundle(draft: draft) }
    func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget, captionInput: TelegramComposerInput,
                 captionAboveMedia: Bool, mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws { throw TelegramPendingUploadPersistenceError.incompatibleData }
    func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile { throw TelegramPendingUploadPersistenceError.incompatibleData }
    func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                           cover: TelegramUploadVideoCover?) async throws { throw TelegramPendingUploadPersistenceError.incompatibleData }
}
