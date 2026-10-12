import XCTest
import AVFoundation
@testable import MakoshTelegram

@MainActor final class TelegramRecordedRoundVideoControllerTests: XCTestCase {
    private let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic round")

    // Catches losing explicit round intent or allowing send before durable storage.
    func testExplicitRoundPreparationPreservesBytesAndExcludesOrdinaryVideoOptions() async throws {
        try await typedPreparation(once: false)
    }
    func testExplicitOnceRoundPreparationFreezesOnceMode() async throws {
        try await typedPreparation(once: true)
    }
    private func typedPreparation(once: Bool) async throws {
        let controller = TelegramUploadController(), provider = RoundControllerProvider()
        controller.bind(provider: provider)
        defer { controller.clear() }
        let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
        var prepared: [UUID] = []
        controller.didPrepare = { _, input, id in XCTAssertEqual(input, .empty); prepared.append(id) }
        guard controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: once) else {
            return XCTFail("Explicit round preparation was refused")
        }
        XCTAssertTrue(controller.isRecordedRoundVideo)
        XCTAssertFalse(controller.showsPreparationPreview)
        try await settled(controller)
        let item = try XCTUnwrap(controller.items.first), id = try XCTUnwrap(controller.preparationContextID)
        XCTAssertEqual(controller.items.count, 1); XCTAssertNil(item.originalFile)
        XCTAssertEqual(item.file.name, "RoundVideo.mp4"); XCTAssertEqual(item.file.mode, .video)
        XCTAssertEqual(item.file.metadata?.roundVideo?.nativeDuration, 2)
        XCTAssertEqual(item.file.metadata?.roundVideo?.isOneTime, once)
        XCTAssertEqual(try Data(contentsOf: item.file.url), bytes)
        XCTAssertEqual(controller.presentation, .media); XCTAssertFalse(controller.isGrouped)
        XCTAssertEqual(controller.captionInput, .empty); XCTAssertFalse(controller.isRecordedVoice)
        XCTAssertTrue(controller.isRecordedRoundVideo); XCTAssertEqual(controller.isOneTimeRoundVideo, once)
        XCTAssertFalse(controller.canEditItems); XCTAssertFalse(controller.canGroupItems)
        XCTAssertFalse(controller.canSwitchPresentation); XCTAssertFalse(controller.canUseMediaOptions)
        XCTAssertFalse(controller.canEditVideoCover); XCTAssertFalse(controller.showsPreparationPreview)
        XCTAssertNil(item.presented(as: .file))
        controller.caption = "caption"
        XCTAssertFalse(controller.updateCaptionInput(try .init(formattedText: .init(text: "caption")), contextID: controller.captionContextID))
        XCTAssertEqual(controller.captionInput, .empty)
        XCTAssertFalse(controller.updatePresentation(.file, contextID: id, revision: controller.itemsRevision))
        XCTAssertFalse(controller.updateGrouping(true, contextID: id, revision: controller.itemsRevision))
        XCTAssertFalse(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertFalse(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertNil(controller.beginVideoCoverEdit(contextID: id, revision: controller.videoCoverRevision))
        await controller.openVideoPreview(contextID: id); XCTAssertNil(controller.videoPlayback.player)
        XCTAssertEqual(prepared, [id]); XCTAssertFalse(controller.canSend)
        controller.send(contextID: id)
        XCTAssertEqual(controller.phase, .ready); XCTAssertNotNil(controller.recoveryStatus)
    }

    // Catches generic-preview bypass, stage consumption, mode changes and stale UI ownership.
    func testPreparedOrdinaryAndOnceRoundPreviewBorrowsExactStage() async throws {
        let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
        for once in [false, true] {
            let controller = TelegramUploadController(), provider = RoundControllerProvider()
            controller.bind(provider: provider); defer { controller.clear() }
            XCTAssertTrue(controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: once))
            try await settled(controller)
            let file = try XCTUnwrap(controller.file), id = try XCTUnwrap(controller.preparationContextID)
            let items = controller.items
            await controller.openRoundVideoPreview(contextID: UUID())
            XCTAssertNil(controller.videoPlayback.player)
            await controller.openVideoPreview(contextID: id)
            XCTAssertNil(controller.videoPlayback.player)
            await controller.openRoundVideoPreview(contextID: id)
            guard let player = controller.videoPlayback.player else { return XCTFail("Explicit round preview is not connected") }
            XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, file.url)
            XCTAssertTrue(player.isMuted); XCTAssertEqual(player.volume, 0); XCTAssertEqual(player.rate, 0)
            controller.stopVideoPreview(contextID: UUID())
            XCTAssertTrue(controller.videoPlayback.player === player)
            await controller.openRoundVideoPreview(contextID: UUID())
            XCTAssertTrue(controller.videoPlayback.player === player)
            XCTAssertEqual(controller.items, items); XCTAssertEqual(controller.isOneTimeRoundVideo, once)
            XCTAssertFalse(controller.canSend, "Preview must not bypass missing durable recovery")
            controller.stopVideoPreview(contextID: id)
            XCTAssertNil(player.currentItem); XCTAssertNil(controller.videoPlayback.player)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        }
    }

    // Catches unlinking a borrowed round stage while AVFoundation is still attached.
    func testRoundPreviewDismissRebindAndClearDetachBeforeUnlink() async throws {
        let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
        for boundary in 0..<3 {
            let controller = TelegramUploadController(), provider = RoundControllerProvider()
            controller.bind(provider: provider); defer { controller.clear() }
            XCTAssertTrue(controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: true))
            try await settled(controller)
            let file = try XCTUnwrap(controller.file), id = try XCTUnwrap(controller.preparationContextID)
            await controller.openRoundVideoPreview(contextID: id)
            guard let player = controller.videoPlayback.player else { return XCTFail("Round decoder was never attached") }
            var released = 0
            controller.discard = { file in
                XCTAssertNil(player.currentItem, "Detach round decoder before unlink")
                released += 1; try TelegramUploadFileIO.discard(file)
            }
            switch boundary {
            case 0: controller.dismissPreparation(contextID: id)
            case 1: controller.bind(provider: nil)
            default: controller.clear()
            }
            XCTAssertNil(controller.videoPlayback.player); XCTAssertNil(player.currentItem)
            XCTAssertEqual(released, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    // Catches an old view stopping/reopening the decoder of a later preparation.
    func testOldRoundContextCannotStopOrReplaceNewPreview() async throws {
        let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
        let controller = TelegramUploadController(), provider = RoundControllerProvider()
        controller.bind(provider: provider); defer { controller.clear() }
        XCTAssertTrue(controller.prepareRecordedRoundVideo(bytes: bytes, target: target))
        try await settled(controller)
        let old = try XCTUnwrap(controller.preparationContextID)
        controller.cancelPreparation()
        XCTAssertTrue(controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: true))
        try await settled(controller)
        let current = try XCTUnwrap(controller.preparationContextID)
        await controller.openRoundVideoPreview(contextID: current)
        guard let player = controller.videoPlayback.player else { return XCTFail("Replacement round preview is not connected") }
        controller.stopVideoPreview(contextID: old)
        await controller.openRoundVideoPreview(contextID: old)
        XCTAssertTrue(controller.videoPlayback.player === player); XCTAssertNotNil(player.currentItem)
        XCTAssertEqual(controller.preparationContextID, current); XCTAssertTrue(controller.isOneTimeRoundVideo)
    }

    // Catches publishing a caption while metadata is still being encoded/probed.
    func testEarlyComposerTransferCannotAddCaption() async throws {
        let controller = TelegramUploadController(), provider = RoundControllerProvider()
        controller.bind(provider: provider); defer { controller.clear() }
        controller.didPrepare = { _,_,_ in controller.caption = "early caption" }
        guard controller.prepareRecordedRoundVideo(bytes: try await recordedRoundVideoFixtureBytes(), target: target) else {
            return XCTFail("Explicit round preparation was refused")
        }
        XCTAssertEqual(controller.captionInput, .empty)
        try await settled(controller); XCTAssertEqual(controller.captionInput, .empty)
    }

    // Catches an asynchronous probe resurrecting a synchronously cancelled/rebound draft.
    func testSynchronousCancellationAndRebindPreventWorkerPublication() async throws {
        let bytes = try await recordedRoundVideoFixtureBytes()
        for rebind in [false,true] {
            let controller = TelegramUploadController(), provider = RoundControllerProvider()
            controller.bind(provider: provider)
            controller.didPrepare = { _,_,_ in
                if rebind { controller.bind(provider: nil) } else { controller.cancelPreparation() }
            }
            XCTAssertFalse(controller.prepareRecordedRoundVideo(bytes: bytes, target: target))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(controller.items.isEmpty); XCTAssertNil(controller.preparationContextID)
            XCTAssertFalse(controller.isRecordedRoundVideo)
            XCTAssertEqual(controller.phase, rebind ? .idle : .cancelled)
            controller.clear()
        }
    }

    // Catches transferring composer ownership to an incompatible account/provider.
    func testPreflightRefusesEmptyWrongAccountAndNonbatchProvider() async throws {
        let bytes = try await recordedRoundVideoFixtureBytes()
        let controller = TelegramUploadController(), single = RoundControllerSingleProvider(), batch = RoundControllerProvider()
        var transferred = false; controller.didPrepare = { _,_,_ in transferred = true }
        controller.bind(provider: single)
        XCTAssertFalse(controller.prepareRecordedRoundVideo(bytes: bytes, target: target))
        controller.bind(provider: batch)
        XCTAssertFalse(controller.prepareRecordedRoundVideo(bytes: Data(), target: target))
        XCTAssertFalse(controller.prepareRecordedRoundVideo(bytes: bytes, target: .init(accountID: 2, chatID: 42, title: "Wrong account")))
        XCTAssertFalse(transferred); XCTAssertEqual(controller.phase, .idle); XCTAssertTrue(controller.items.isEmpty)
    }

    // Catches replacement during an active preparation or stale completion after cancellation.
    func testCancelReleasesRoundRestrictionsAndAllowsNewPreparation() async throws {
        let bytes = try await recordedRoundVideoFixtureBytes(), controller = TelegramUploadController(), provider = RoundControllerProvider()
        controller.bind(provider: provider); defer { controller.clear() }
        guard controller.prepareRecordedRoundVideo(bytes: bytes, target: target) else { return XCTFail("Explicit round preparation was refused") }
        let first = controller.preparationContextID
        XCTAssertFalse(controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: true))
        controller.cancelPreparation(); XCTAssertFalse(controller.isRecordedRoundVideo)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertTrue(controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: true))
        XCTAssertNotEqual(controller.preparationContextID, first)
        try await settled(controller); XCTAssertTrue(controller.isOneTimeRoundVideo)
    }
    private func settled(_ controller: TelegramUploadController) async throws {
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
    }
}

@MainActor private class RoundControllerSingleProvider: TelegramUploadProvider {
    let accountID: Int64 = 1
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
        caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
        receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        receive(.rejected); return RoundControllerLease()
    }
}
@MainActor private final class RoundControllerProvider: RoundControllerSingleProvider, TelegramUploadBatchProvider {
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
        receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        receive(.rejected); return RoundControllerLease()
    }
}
@MainActor private final class RoundControllerLease: TelegramUploadLease { func stop() {} }
