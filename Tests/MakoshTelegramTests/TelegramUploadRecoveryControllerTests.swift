import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

@MainActor final class TelegramUploadRecoveryControllerTests: XCTestCase {
    private final class Lease: TelegramUploadLease { func stop() {} }
    private final class Provider: TelegramUploadProvider {
        let accountID: Int64 = 1
        var calls = 0
        var submissions: [(UUID, TelegramFormattedText)] = []
        var placements: [Bool] = []
        var spoilers: [Bool] = []
        var files: [TelegramUploadFile] = []
        var callback: (@MainActor (TelegramUploadEvent) -> Void)?
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
                    receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
            submissions.append((preparationID, caption))
            files.append(file)
            placements.append(captionAboveMedia)
            spoilers.append(mediaSpoiler)
            calls += 1; callback = receive; return Lease()
        }
    }
    private enum Failure: Error { case synthetic }
    private final class Store: TelegramUploadRecoveryStore {
        let accountID: Int64 = 1
        var prepareGate: CheckedContinuation<Void, Error>?
        var saveGate: CheckedContinuation<Void, Error>?
        var cancelGate: CheckedContinuation<Void, Error>?
        var holdCancel = false
        var holdPrepare = false, holdSubmission = false, failPrepare = false, failAccepted = false
        var failPrepared = false
        var failSubmission = false
        var prepares = 0
        var preparedIDs: [UUID] = []
        var savedIDs: [UUID] = []
        var saves: [(TelegramComposerInput, TelegramPendingUploadDisposition)] = []
        var placements: [Bool] = []
        var spoilers: [Bool] = []
        func load(chatID: Int64) async throws -> TelegramPendingUploadDraft? { nil }
        func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile { throw Failure.synthetic }
        func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                               cover: TelegramUploadVideoCover?) async throws { throw Failure.synthetic }
        func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                     captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, originalDraft: TelegramComposerDraft?) async throws {
            preparedIDs.append(preparationID)
            prepares += 1
            if failPrepare { throw Failure.synthetic }
            if holdPrepare { try await withCheckedThrowingContinuation { prepareGate = $0 } }
        }
        func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
                  disposition: TelegramPendingUploadDisposition) async throws {
            savedIDs.append(preparationID)
            saves.append((captionInput, disposition))
            placements.append(captionAboveMedia)
            spoilers.append(mediaSpoiler)
            if case .prepared = disposition, failPrepared { throw Failure.synthetic }
            if case .cancelled = disposition, holdCancel {
                try await withCheckedThrowingContinuation { cancelGate = $0 }
            }
            if case .accepted = disposition, failAccepted { throw Failure.synthetic }
            if case .submissionStarted = disposition, failSubmission { throw Failure.synthetic }
            if case .submissionStarted = disposition, holdSubmission {
                try await withCheckedThrowingContinuation { saveGate = $0 }
            }
        }
    }
    private let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
    private func drain() async { for _ in 0..<100 { await Task.yield() } }
    private func setup(store: Store, mode: TelegramUploadMode = .file) -> (TelegramUploadController, Provider) {
        let controller = TelegramUploadController(), provider = Provider()
        controller.stage = { _, _ in .init(id: UUID(), name: "synthetic.txt", size: 1, mode: mode,
            pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/synthetic/payload"), directory: URL(fileURLWithPath: "/synthetic")) }
        controller.discard = { _ in }
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        controller.prepare(source: URL(fileURLWithPath: "/synthetic/source"), mode: mode, target: target, caption: "original")
        return (controller, provider)
    }
    func testCoveredVideoRecoveryRejectsDroppedCoverAndPreviewsCoverWithoutAutoplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("portrait.mp4"), image = root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(source, rotated: true, timescale: 30)
        try writeUploadVideoCoverFixture(image)
        let original = try await TelegramUploadFileIO.stage(source, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(original); try? TelegramUploadFileIO.discard(cover.imageFile) }
        let file = TelegramUploadFile(id: original.id, name: original.name, size: original.size, mode: .video,
            pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, url: original.url, directory: original.directory,
            video: original.video, videoCover: cover)
        let draft = try pendingUploadMutating(pendingUploadVideoCoverFixture()) {
            var record = $0["file"] as! [String: Any], attachment = record["attachment"] as! [String: Any]
            attachment["name"] = file.name; attachment["size"] = file.size
            record["attachment"] = attachment; record["plaintextByteCount"] = file.size; $0["file"] = record
            var saved = $0["videoCover"] as! [String: Any], stored = saved["file"] as! [String: Any], a = stored["attachment"] as! [String: Any]
            a["name"] = cover.name; a["size"] = cover.size; stored["attachment"] = a
            stored["plaintextByteCount"] = cover.size; stored["plaintextSHA256"] = cover.sha256
            saved["file"] = stored; saved["width"] = 40; saved["height"] = 80; $0["videoCover"] = saved
        }
        let dropped = TelegramUploadController(), store = Store(), provider = Provider()
        dropped.discard = { _ in }
        dropped.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        let restoredWithoutCover = dropped.restore(draft: draft, file: original, target: target, restorationEpoch: dropped.recoveryRestoreEpoch)
        XCTAssertFalse(restoredWithoutCover, "Recovery must never drop the saved cover")
        let controller = TelegramUploadController()
        controller.discard = { _ in }
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: draft, file: file, target: target, restorationEpoch: controller.recoveryRestoreEpoch))
        let preview = try await TelegramUploadFileIO.preview(file)
        XCTAssertEqual(preview.image.width, 40); XCTAssertEqual(preview.image.height, 80)
        XCTAssertEqual(preview.originalSHA256, cover.sha256)
        await controller.openVideoPreview(contextID: draft.id)
        XCTAssertNil(controller.videoPlayback.player, "Reference disables autoplay when a custom cover is selected")
        XCTAssertNil(controller.videoPlayback.error)
        controller.send(contextID: draft.id); await drain()
        XCTAssertEqual(provider.files.first?.videoCover, cover)
    }
    func testOwnedVideoRecoveryPreservesDescriptorAndOptionsWithoutResendingUnknownSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("portrait.mp4")
        try await writeUploadVideoFixture(source, rotated: true, timescale: 30)
        for unknown in [false, true] {
            let file = try await TelegramUploadFileIO.stage(source, mode: .video)
            addTeardownBlock { try TelegramUploadFileIO.discard(file) }
            let draft = try pendingUploadMutating(pendingUploadVideoFixture(disposition: unknown ? .submissionStarted : .prepared)) {
                $0["mediaSpoiler"] = true; $0["captionAboveMedia"] = true
                var record = $0["file"] as! [String: Any], attachment = record["attachment"] as! [String: Any]
                attachment["name"] = file.name; attachment["size"] = file.size
                record["attachment"] = attachment; record["plaintextByteCount"] = file.size; $0["file"] = record
            }
            let controller = TelegramUploadController(), store = Store(), provider = Provider()
            controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            let video = try XCTUnwrap(file.video)
            let wrong = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .video,
                pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory,
                video: .init(width: video.width, height: video.height, duration: video.duration, hasAudio: video.hasAudio, inCollage: false))
            XCTAssertFalse(controller.restore(draft: draft, file: wrong, target: target, restorationEpoch: controller.recoveryRestoreEpoch))
            XCTAssertTrue(controller.restore(draft: draft, file: file, target: target, restorationEpoch: controller.recoveryRestoreEpoch))
            XCTAssertEqual(controller.file?.video, file.video)
            XCTAssertEqual(controller.captionInput, draft.captionInput)
            XCTAssertTrue(controller.captionAboveMedia); XCTAssertTrue(controller.mediaSpoiler)
            XCTAssertEqual(controller.canSend, !unknown)
            if unknown {
                controller.send(); await drain(); XCTAssertEqual(provider.calls, 0)
                XCTAssertFalse(controller.updateMediaSpoiler(false, contextID: controller.captionContextID, revision: controller.captionRevision))
            } else {
                XCTAssertTrue(controller.updateCaptionPlacement(false, contextID: controller.captionContextID, revision: controller.captionRevision))
                XCTAssertTrue(controller.updateMediaSpoiler(false, contextID: controller.captionContextID, revision: controller.captionRevision))
                controller.sendAsSpoiler(contextID: draft.id, revision: controller.captionRevision)
                await drain()
                XCTAssertEqual(provider.calls, 1)
                XCTAssertEqual(provider.files.first?.video, file.video)
                XCTAssertEqual(provider.placements, [false]); XCTAssertEqual(provider.spoilers, [true])
                XCTAssertFalse(controller.mediaSpoiler, "One-shot video spoiler cannot mutate preview choice")
            }
        }
    }
    func testOneShotSpoilerPersistsFrozenMarkerAndAcceptanceRetryWithoutTogglingPreview() async throws {
        let store = Store(); store.holdPrepare = true; store.holdSubmission = true
        let (controller, provider) = setup(store: store, mode: .photo)
        await drain()
        let id = try XCTUnwrap(controller.preparationContextID)
        controller.sendAsSpoiler(contextID: id, revision: controller.captionRevision)
        XCTAssertTrue(store.saves.isEmpty); XCTAssertEqual(provider.calls, 0)
        store.prepareGate?.resume(); store.prepareGate = nil; await drain()
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "😀", entities: [.init(offset: 0, length: 2, kind: .italic)]))
        XCTAssertTrue(controller.updateCaptionInput(input, contextID: controller.captionContextID))
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        controller.sendAsSpoiler(contextID: id, revision: controller.captionRevision)
        await drain()
        XCTAssertNotNil(store.saveGate); XCTAssertEqual(store.saves.last?.1, .submissionStarted)
        XCTAssertEqual(store.saves.last?.0, input); XCTAssertEqual(store.spoilers.last, true)
        XCTAssertEqual(store.placements.last, true); XCTAssertFalse(controller.mediaSpoiler)
        XCTAssertEqual(provider.calls, 0)
        controller.caption = "newer input after frozen send"
        store.saveGate?.resume(); store.saveGate = nil; await drain()
        XCTAssertEqual(provider.spoilers, [true]); XCTAssertEqual(provider.placements, [true])
        XCTAssertEqual(provider.submissions.first?.1, input.formattedText)
        store.failAccepted = true
        provider.callback?(.committing); provider.callback?(.accepted("receipt")); await drain()
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertEqual(store.spoilers.last, true)
        store.failAccepted = false; controller.retryRecovery(); await drain()
        XCTAssertEqual(provider.calls, 1); XCTAssertEqual(store.saves.last?.1, .accepted(localMessageID: "receipt"))
        XCTAssertEqual(store.saves.last?.0, input); XCTAssertEqual(store.spoilers.last, true)
        XCTAssertFalse(controller.mediaSpoiler)
    }
    func testOneShotSpoilerUnconfirmedMarkerNeverSubmitsOrRetriesSend() async throws {
        let store = Store(); store.failSubmission = true
        let (controller, provider) = setup(store: store, mode: .photo)
        await drain()
        let id = try XCTUnwrap(controller.preparationContextID)
        controller.sendAsSpoiler(contextID: id, revision: controller.captionRevision); await drain()
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(store.saves.last?.1, .submissionStarted); XCTAssertEqual(store.spoilers.last, true)
        controller.sendAsSpoiler(contextID: id, revision: controller.captionRevision); controller.retryRecovery(); await drain()
        XCTAssertEqual(provider.calls, 0); XCTAssertFalse(controller.canRetryRecovery)
    }
    func testRebindDuringInitialWritePreservesLatestRichCaptionAndBothPhotoOptionsInOriginalStore() async throws {
        let store = Store(); store.holdPrepare = true
        let (controller, provider) = setup(store: store, mode: .photo)
        await drain(); XCTAssertNotNil(store.prepareGate)
        let rich = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "😀", entities: [.init(offset: 0, length: 2, kind: .bold)]))
        XCTAssertTrue(controller.updateCaptionInput(rich, contextID: controller.captionContextID))
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        let next = Store()
        controller.bind(provider: Provider(), recoveryStore: next, requiresRecovery: true)
        store.prepareGate?.resume(); store.prepareGate = nil
        await drain()
        XCTAssertEqual(store.saves.last?.1, .prepared)
        XCTAssertEqual(store.saves.last?.0, rich)
        XCTAssertEqual(store.placements.last, true); XCTAssertEqual(store.spoilers.last, true)
        XCTAssertTrue(next.saves.isEmpty); XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(controller.phase, .idle); XCTAssertFalse(controller.mediaSpoiler)
    }
    func testDetachedWriteFailureRetriesOnlyOriginalStoreWithoutSubmitting() async {
        let store = Store(); store.holdPrepare = true; store.failPrepared = true
        let (controller, provider) = setup(store: store, mode: .photo)
        await drain()
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        let next = Store()
        controller.bind(provider: Provider(), recoveryStore: next, requiresRecovery: true)
        store.prepareGate?.resume(); store.prepareGate = nil
        await drain()
        XCTAssertNotNil(controller.detachedRecoveryStatus); XCTAssertTrue(controller.canRetryDetachedRecovery)
        store.failPrepared = false; controller.retryDetachedRecovery(); await drain()
        XCTAssertNil(controller.detachedRecoveryStatus); XCTAssertFalse(controller.canRetryDetachedRecovery)
        XCTAssertEqual(store.saves.last?.1, .prepared); XCTAssertEqual(store.spoilers.last, true)
        XCTAssertTrue(next.saves.isEmpty); XCTAssertEqual(provider.calls, 0)
    }
    func testRebindImmediatelyAfterReadyOptionChangePersistsLatestTuple() async {
        let store = Store()
        let (controller, provider) = setup(store: store, mode: .photo)
        await drain(); XCTAssertTrue(controller.canSend)
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        let next = Store()
        controller.bind(provider: Provider(), recoveryStore: next, requiresRecovery: true)
        await drain()
        XCTAssertEqual(store.saves.last?.1, .prepared)
        XCTAssertEqual(store.spoilers.last, true); XCTAssertEqual(store.placements.last, true)
        XCTAssertTrue(next.saves.isEmpty); XCTAssertEqual(provider.calls, 0)
    }
    func testSpoilerRestoresWithOwnedPhotoButUnknownSubmissionCannotChangeIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.jpg")
        let image = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        for unknown in [false, true] {
            let file = try await TelegramUploadFileIO.stage(source, mode: .photo)
            addTeardownBlock { try TelegramUploadFileIO.discard(file) }
            let draft = try pendingUploadMutating(pendingUploadFixture(disposition: unknown ? .submissionStarted : .prepared)) {
                $0["mediaSpoiler"] = true; $0["captionAboveMedia"] = true
                var record = $0["file"] as! [String: Any], attachment = record["attachment"] as! [String: Any]
                attachment["kind"] = "photo"; attachment["name"] = file.name; attachment["size"] = file.size
                record["attachment"] = attachment; record["plaintextByteCount"] = file.size; $0["file"] = record
            }
            let controller = TelegramUploadController(), provider = Provider(), store = Store()
            controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            XCTAssertTrue(controller.restore(draft: draft, file: file, target: target, restorationEpoch: controller.recoveryRestoreEpoch))
            XCTAssertTrue(controller.mediaSpoiler); XCTAssertTrue(controller.captionAboveMedia)
            XCTAssertEqual(controller.captionInput, draft.captionInput)
            XCTAssertEqual(controller.phase, unknown ? .uncertain : .ready)
            XCTAssertEqual(provider.calls, 0)
            XCTAssertEqual(controller.updateMediaSpoiler(false, contextID: controller.captionContextID, revision: controller.captionRevision), !unknown)
            controller.clear()
        }
    }
    func testPlacementDuringInitialPersistenceIsSavedAndFrozenThroughAcceptanceRetry() async throws {
        let store = Store(); store.holdPrepare = true; store.holdSubmission = true
        let (controller, provider) = setup(store: store, mode: .photo)
        await drain(); XCTAssertNotNil(store.prepareGate)
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        store.prepareGate?.resume(); store.prepareGate = nil
        await drain()
        XCTAssertEqual(store.placements.last, true, "Initial save must catch a newer placement even with identical input")
        XCTAssertEqual(store.spoilers.last, true)
        controller.send(); await drain(); XCTAssertNotNil(store.saveGate)
        XCTAssertEqual(store.placements.last, true)
        XCTAssertFalse(controller.updateCaptionPlacement(false, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertFalse(controller.updateMediaSpoiler(false, contextID: controller.captionContextID, revision: controller.captionRevision))
        controller.caption = "newer input after frozen send"
        store.saveGate?.resume(); store.saveGate = nil
        await drain(); XCTAssertEqual(provider.placements, [true])
        XCTAssertEqual(provider.spoilers, [true])
        store.failAccepted = true
        provider.callback?(.committing); provider.callback?(.accepted("receipt"))
        await drain(); XCTAssertEqual(controller.phase, .uncertain)
        XCTAssertEqual(store.saves.last?.0.formattedText.text, "original"); XCTAssertEqual(store.placements.last, true)
        XCTAssertEqual(store.spoilers.last, true)
        store.failAccepted = false; controller.retryRecovery(); await drain()
        XCTAssertEqual(provider.calls, 1); XCTAssertEqual(store.placements.last, true)
        XCTAssertEqual(store.spoilers.last, true)
        XCTAssertEqual(controller.caption, "newer input after frozen send")
    }
    func testCancellationDuringInitialWriteRetainsFrozenCaptionAndPlacementAfterRebind() async throws {
        let store = Store(); store.holdPrepare = true
        let (controller, _) = setup(store: store, mode: .photo)
        await drain(); XCTAssertNotNil(store.prepareGate)
        controller.caption = "cancelled caption 😀"
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        controller.cancelPreparation(); controller.clear()
        let nextStore = Store()
        controller.bind(provider: Provider(), recoveryStore: nextStore, requiresRecovery: true)
        store.prepareGate?.resume(); store.prepareGate = nil
        await drain()
        XCTAssertEqual(store.saves.last?.1, .cancelled)
        XCTAssertEqual(store.saves.last?.0.formattedText.text, "cancelled caption 😀")
        XCTAssertEqual(store.placements.last, true)
        XCTAssertEqual(store.spoilers.last, true)
        XCTAssertTrue(nextStore.saves.isEmpty)
        XCTAssertEqual(controller.phase, .idle); XCTAssertFalse(controller.captionAboveMedia)
        XCTAssertFalse(controller.mediaSpoiler)
    }
    func testInitialPersistenceAndLatestCaptionSubmissionGateProvider() async throws {
        let store = Store(); store.holdPrepare = true; store.holdSubmission = true
        let (controller, provider) = setup(store: store)
        let preparationID = try XCTUnwrap(controller.preparationContextID)
        controller.send(contextID: UUID())
        XCTAssertEqual(provider.calls, 0)
        await drain(); XCTAssertNotNil(store.prepareGate)
        controller.send(); XCTAssertEqual(provider.calls, 0); XCTAssertFalse(controller.canSend)
        controller.caption = "latest 😀"
        store.prepareGate?.resume(); store.prepareGate = nil
        await drain(); XCTAssertTrue(controller.canSend)
        controller.send(); await drain()
        XCTAssertNotNil(store.saveGate); XCTAssertEqual(provider.calls, 0)
        guard case .submissionStarted = store.saves.last?.1 else { return XCTFail("Marker before provider") }
        XCTAssertEqual(store.saves.last?.0.formattedText.text, "latest 😀")
        store.saveGate?.resume(); store.saveGate = nil
        await drain(); XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(store.preparedIDs, [preparationID])
        XCTAssertTrue(store.savedIDs.allSatisfy { $0 == preparationID })
        XCTAssertEqual(provider.submissions.first?.0, preparationID)
        XCTAssertEqual(provider.submissions.first?.1.text, "latest 😀")
        store.failAccepted = true
        provider.callback?(.committing); provider.callback?(.accepted("receipt"))
        await drain()
        store.failAccepted = false; controller.retryRecovery(); await drain()
        XCTAssertEqual(provider.submissions.count, 1, "Accepted marker retry never resubmits")
        XCTAssertTrue(store.savedIDs.allSatisfy { $0 == preparationID })
    }
    func testRebindWhileSubmissionMarkerPendingNeverDispatchesOldPreparation() async throws {
        let store = Store(); store.holdSubmission = true
        let (controller, provider) = setup(store: store)
        await drain()
        let oldID = try XCTUnwrap(controller.preparationContextID)
        controller.send(contextID: oldID); await drain()
        XCTAssertNotNil(store.saveGate)
        let nextStore = Store(), nextProvider = Provider()
        controller.bind(provider: nextProvider, recoveryStore: nextStore, requiresRecovery: true)
        controller.prepare(source: URL(fileURLWithPath: "/synthetic/new"), mode: .file, target: target, caption: "new")
        await drain()
        let newID = try XCTUnwrap(controller.preparationContextID)
        XCTAssertNotEqual(oldID, newID)
        store.saveGate?.resume(); store.saveGate = nil
        await drain()
        controller.send(contextID: oldID)
        XCTAssertEqual(provider.calls, 0); XCTAssertEqual(nextProvider.calls, 0)
        controller.send(contextID: newID); await drain()
        XCTAssertEqual(nextProvider.submissions.first?.0, newID)
        XCTAssertEqual(nextProvider.submissions.first?.1.text, "new")
        XCTAssertEqual(nextStore.preparedIDs, [newID])
        XCTAssertTrue(nextStore.savedIDs.allSatisfy { $0 == newID })
    }
    func testPrepareFailureBlocksAndAcceptedSaveFailureNeverResubmits() async {
        let store = Store(); store.failPrepare = true
        let (controller, provider) = setup(store: store)
        await drain(); XCTAssertFalse(controller.canSend); XCTAssertTrue(controller.canRetryRecovery)
        controller.send(); XCTAssertEqual(provider.calls, 0)
        store.failPrepare = false; controller.retryRecovery(); await drain()
        XCTAssertTrue(controller.canSend)
        store.failAccepted = true
        var queued = 0, finished = 0
        controller.didQueue = { _, _ in queued += 1 }
        controller.didFinishPreparation = { _ in finished += 1 }
        controller.send(); await drain()
        provider.callback?(.committing); provider.callback?(.accepted("local-only"))
        await drain(); XCTAssertEqual(controller.phase, .uncertain)
        XCTAssertEqual(queued, 0); XCTAssertEqual(finished, 0)
        controller.send(); XCTAssertEqual(provider.calls, 1)
        store.failAccepted = false; controller.retryRecovery(); await drain()
        XCTAssertEqual(queued, 1); XCTAssertEqual(finished, 1); XCTAssertEqual(provider.calls, 1)
    }
    func testCancellationAfterPendingPrepareTombstonesLateCompletionAndBindPreserves() async {
        let store = Store(); store.holdPrepare = true
        let (controller, provider) = setup(store: store)
        await drain(); controller.cancelPreparation()
        store.prepareGate?.resume(); store.prepareGate = nil
        await drain(); XCTAssertEqual(provider.calls, 0)
        guard case .cancelled = store.saves.last?.1 else { return XCTFail("Late prepare must not resurrect cancelled draft") }
        let nextStore = Store(); nextStore.holdPrepare = true
        let (next, _) = setup(store: nextStore)
        await drain(); next.bind(provider: nil)
        nextStore.prepareGate?.resume(); nextStore.prepareGate = nil
        await drain()
        XCTAssertFalse(nextStore.saves.contains { if case .cancelled = $0.1 { true } else { false } })
        XCTAssertEqual(next.phase, .idle)
    }
    func testDismissedCancellationFailureRetriesOnlyOriginalStorage() async throws {
        let store = Store(); store.holdCancel = true
        let (controller, provider) = setup(store: store)
        await drain()
        let id = try XCTUnwrap(controller.preparationContextID)
        controller.dismissPreparation(contextID: id)
        await drain()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNotNil(store.cancelGate)
        store.cancelGate?.resume(throwing: Failure.synthetic); store.cancelGate = nil
        await drain()
        XCTAssertNotNil(controller.cancellationStatus)
        XCTAssertTrue(controller.canRetryCancellation)
        XCTAssertEqual(store.saves.count, 1, "Dismiss must not duplicate cancellation")
        store.holdCancel = false
        controller.retryCancellation(); await drain()
        XCTAssertNil(controller.cancellationStatus)
        XCTAssertEqual(store.saves.count, 2)
        XCTAssertEqual(store.prepares, 1)
        XCTAssertEqual(provider.calls, 0)
        XCTAssertTrue(store.saves.allSatisfy { if case .cancelled = $0.1 { true } else { false } })
        XCTAssertEqual(store.saves.last?.0.formattedText.text, "original")
    }
    func testLateInitialFailureCancellationCannotCorruptNewPreparation() async throws {
        let store = Store(); store.holdPrepare = true; store.holdCancel = true
        let (controller, provider) = setup(store: store)
        await drain()
        controller.dismissPreparation(contextID: try XCTUnwrap(controller.preparationContextID))
        store.prepareGate?.resume(throwing: Failure.synthetic); store.prepareGate = nil
        await drain()
        XCTAssertNotNil(store.cancelGate, "Uncertain initial write still needs cancellation")
        store.holdPrepare = false
        controller.prepare(source: URL(fileURLWithPath: "/synthetic/new"), mode: .file, target: target, caption: "new")
        await drain()
        store.cancelGate?.resume(throwing: Failure.synthetic); store.cancelGate = nil
        await drain()
        XCTAssertEqual(controller.caption, "new")
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNil(controller.cancellationStatus)
        XCTAssertFalse(controller.canRetryCancellation)
        XCTAssertEqual(provider.calls, 0)
    }
    func testRestoredStartedIsUncertainAndNeverSubmits() async throws {
        let store = Store(), controller = TelegramUploadController(), provider = Provider()
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        let draft = try pendingUploadFixture(disposition: .submissionStarted)
        let id = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("payload-" + id.uuidString)
        try Data("Synthetic 😀".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = TelegramUploadFile(id: id, name: draft.file.attachment.name, size: draft.file.plaintextByteCount,
            mode: .file, pixelWidth: nil, pixelHeight: nil, url: url, directory: directory)
        XCTAssertTrue(controller.restore(draft: draft, file: file, target: target, restorationEpoch: controller.recoveryRestoreEpoch))
        XCTAssertEqual(controller.phase, .uncertain); controller.send(); await drain()
        XCTAssertEqual(provider.calls, 0)
        controller.clear(); await drain()
        XCTAssertTrue(store.saves.isEmpty, "Uncertain close preserves submission marker")
    }
}
