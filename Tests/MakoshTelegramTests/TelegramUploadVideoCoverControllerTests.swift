import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramUploadVideoCoverControllerTests: XCTestCase {
    private final class Lease: TelegramUploadLease { func stop() {} }
    private final class Provider: TelegramUploadProvider {
        let accountID: Int64
        var files: [TelegramUploadFile] = []
        var captions: [TelegramFormattedText] = []
        init(_ accountID: Int64 = 1) { self.accountID = accountID }
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
                    caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
                    receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
            files.append(file); captions.append(caption); receive(.accepted("synthetic")); return Lease()
        }
    }
    private final class Store: TelegramUploadRecoveryStore {
        let accountID: Int64 = 1
        var failCover = false, holdCover = false, failCaption = false
        var gate: CheckedContinuation<Void, Error>?
        func load(chatID: Int64) async throws -> TelegramPendingUploadDraft? { nil }
        func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                     captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool,
                     originalDraft: TelegramComposerDraft?) async throws {}
        func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput,
                  captionAboveMedia: Bool, mediaSpoiler: Bool, disposition: TelegramPendingUploadDisposition) async throws {
            if failCaption, disposition == .prepared { throw TelegramUploadFileError.unavailable }
        }
        func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile { throw TelegramUploadFileError.unavailable }
        func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                               cover: TelegramUploadVideoCover?) async throws {
            if holdCover { try await withCheckedThrowingContinuation { gate = $0 } }
            if failCover { throw TelegramUploadFileError.unavailable }
        }
    }
    private func fixture() async throws -> (TelegramUploadController, Provider, Store, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("synthetic.mov"), image = root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(video); try writeUploadVideoCoverFixture(image)
        let controller = TelegramUploadController(), provider = Provider(), store = Store()
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        controller.prepare(source: video, mode: .video, target: .init(accountID: 1, chatID: 42, title: "Synthetic"), caption: "Caption 😀")
        await eventually { controller.canSend }
        return (controller, provider, store, image)
    }
    private func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }

    // Catches comparing a restored preparation's durable ID with the separate
    // caption generation, which made every Add/Change/Remove action a no-op.
    func testRestoredPreparationCanAddAndRemoveCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("portrait.mp4"), image = root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(video, rotated: true, timescale: 30)
        try writeUploadVideoCoverFixture(image)
        let file = try await TelegramUploadFileIO.stage(video, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(file); try? TelegramUploadFileIO.discard(cover.imageFile) }
        let draft = try pendingUploadMutating(pendingUploadVideoFixture()) {
            var record = $0["file"] as! [String: Any], attachment = record["attachment"] as! [String: Any]
            attachment["name"] = file.name; attachment["size"] = file.size
            record["attachment"] = attachment; record["plaintextByteCount"] = file.size; $0["file"] = record
        }
        let controller = TelegramUploadController(), store = Store(), provider = Provider()
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        defer { controller.clear() }
        XCTAssertTrue(controller.restore(draft: draft, file: file, target: .init(accountID: 1, chatID: 42, title: "Synthetic"), restorationEpoch: controller.recoveryRestoreEpoch))
        XCTAssertTrue(controller.canEditVideoCover)
        let add = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: draft.id, revision: controller.videoCoverRevision))
        XCTAssertTrue(controller.commitVideoCover(cover, editID: add))
        await eventually { controller.canSend }
        XCTAssertEqual(controller.file?.videoCover, cover)
        let remove = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: draft.id, revision: controller.videoCoverRevision))
        XCTAssertTrue(controller.commitVideoCover(nil, editID: remove))
        await eventually { controller.canSend }
        XCTAssertNil(controller.file?.videoCover)
    }

    // Catches confirming a cover while an earlier caption write failed, then
    // losing the visible caption on restart. The whole preparation must be
    // durable before sending can resume, including on explicit retry.
    func testFailedCaptionIsResavedWithCoverBeforeSendCanResume() async throws {
        let (controller, provider, store, source) = try await fixture()
        defer { controller.clear() }
        store.failCaption = true
        controller.caption = "Edited caption 😀"
        await eventually { controller.canRetryRecovery }
        let cover = try await TelegramUploadVideoCoverIO.stage(source, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        let context = try XCTUnwrap(controller.preparationContextID)
        let edit = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: context, revision: controller.videoCoverRevision))
        XCTAssertTrue(controller.commitVideoCover(cover, editID: edit))
        await eventually { !controller.isRecoveryBusy }
        XCTAssertTrue(controller.canRetryRecovery)
        XCTAssertFalse(controller.canSend)
        controller.send(contextID: context); XCTAssertTrue(provider.files.isEmpty)
        store.failCaption = false; controller.retryRecovery()
        await eventually { controller.canSend }
        controller.send(contextID: context)
        await eventually { provider.files.count == 1 }
        XCTAssertEqual(provider.captions.first?.text, "Edited caption 😀")
    }

    // Catches sending behind the picker, applying an old editor, dropping the
    // caption on change/removal, and leaving released cover stages behind.
    func testEditorContextBlocksSendAndRejectsStaleApplyWhileRemovalRestoresOriginal() async throws {
        let (controller, provider, _, source) = try await fixture()
        defer { controller.clear() }
        let context = try XCTUnwrap(controller.preparationContextID), original = try XCTUnwrap(controller.file)
        let first = try await TelegramUploadVideoCoverIO.stage(source, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(first.imageFile) }
        XCTAssertTrue(controller.canEditVideoCover)
        let edit = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: context, revision: controller.videoCoverRevision))
        XCTAssertFalse(controller.canSend)
        controller.send(contextID: context); XCTAssertTrue(provider.files.isEmpty)
        XCTAssertTrue(controller.commitVideoCover(first, editID: edit))
        await eventually { !controller.isRecoveryBusy && controller.canSend }
        XCTAssertEqual(controller.file?.videoCover, first); XCTAssertEqual(controller.caption, "Caption 😀")
        XCTAssertFalse(controller.commitVideoCover(nil, editID: edit), "Stale editor cannot remove the committed cover")
        let remove = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: context, revision: controller.videoCoverRevision))
        XCTAssertTrue(controller.commitVideoCover(nil, editID: remove))
        await eventually { !controller.isRecoveryBusy && controller.canSend }
        XCTAssertNil(controller.file?.videoCover); XCTAssertEqual(controller.file?.id, original.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        let cancelled = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: context, revision: controller.videoCoverRevision))
        controller.cancelVideoCoverEdit(cancelled)
        XCTAssertTrue(controller.canSend)
        XCTAssertFalse(controller.commitVideoCover(first, editID: cancelled))
    }

    // Catches publishing a sendable preparation after a failed/unknown cover
    // write, retrying send automatically, or losing the candidate before retry.
    func testFailedCoverAcknowledgementBlocksSendUntilExplicitPersistenceRetry() async throws {
        let (controller, provider, store, source) = try await fixture()
        defer { controller.clear() }
        store.failCover = true
        let cover = try await TelegramUploadVideoCoverIO.stage(source, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        let context = try XCTUnwrap(controller.preparationContextID)
        let edit = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: context, revision: controller.videoCoverRevision))
        XCTAssertTrue(controller.commitVideoCover(cover, editID: edit))
        await eventually { controller.canRetryRecovery }
        XCTAssertFalse(controller.canSend); XCTAssertFalse(controller.canEditVideoCover)
        XCTAssertEqual(controller.file?.videoCover, cover)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.url.path))
        controller.send(contextID: context); XCTAssertTrue(provider.files.isEmpty)
        store.failCover = false; controller.retryRecovery()
        await eventually { controller.canSend }
        controller.send(contextID: context)
        await eventually { provider.files.count == 1 }
        XCTAssertEqual(provider.files.first?.videoCover, cover)
    }

    // Catches a late account-bound save mutating the next account's window or
    // accepting an editor whose originating preparation has been detached.
    func testRebindDuringCoverSaveCannotApplyLateResultToNewAccount() async throws {
        let (controller, _, store, source) = try await fixture()
        defer { controller.clear() }
        store.holdCover = true
        let cover = try await TelegramUploadVideoCoverIO.stage(source, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        let context = try XCTUnwrap(controller.preparationContextID)
        let edit = try XCTUnwrap(controller.beginVideoCoverEdit(contextID: context, revision: controller.videoCoverRevision))
        XCTAssertTrue(controller.commitVideoCover(cover, editID: edit))
        await eventually { store.gate != nil }
        controller.bind(provider: Provider(2))
        store.gate?.resume(); store.gate = nil
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(controller.phase, .idle); XCTAssertNil(controller.file)
        XCTAssertNil(controller.videoCoverEditingID); XCTAssertFalse(controller.canSend)
        XCTAssertFalse(controller.commitVideoCover(cover, editID: edit))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.url.path))
    }
}
