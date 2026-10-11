import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramRecordedVoiceControllerTests: XCTestCase {
    private let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic voice")

    // Catches routing explicit recorded PCM through ordinary file classification,
    // losing its waveform, or admitting it before durable recovery succeeds.
    func testRecordingCreatesOneTypedBatchAndWaitsForDurability() async throws {
        let controller = TelegramUploadController(), provider = VoiceControllerProvider()
        controller.bind(provider: provider)
        var prepared: [(TelegramUploadTarget, TelegramComposerInput, UUID)] = []
        controller.didPrepare = { prepared.append(($0, $1, $2)) }
        defer { controller.clear() }
        XCTAssertTrue(controller.prepareRecordedVoice(samples: pulse(count: 48_137), target: target))
        try await settled(controller)
        XCTAssertEqual(controller.phase, .ready)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertEqual(controller.items.count, 1); XCTAssertNil(item.originalFile)
        XCTAssertEqual(item.file.mode, .file); XCTAssertEqual(item.file.name, "Voice.ogg")
        XCTAssertEqual(item.file.metadata?.voice?.sampleCount, 48_137)
        var waveform = Data(repeating: 0, count: 63); waveform[0] = 0x0c
        XCTAssertEqual(item.file.metadata?.voice?.waveform, waveform)
        let decoded = try await TelegramRecordedVoiceCodec.decodeRecording(Data(contentsOf: item.file.url))
        XCTAssertEqual(decoded.count, 48_137)
        XCTAssertEqual(controller.presentation, .file); XCTAssertFalse(controller.isGrouped)
        XCTAssertEqual(controller.captionInput, .empty)
        XCTAssertFalse(controller.canSwitchPresentation); XCTAssertFalse(controller.canUseMediaOptions)
        XCTAssertEqual(prepared.count, 1); XCTAssertEqual(prepared.first?.0, target)
        XCTAssertEqual(prepared.first?.1, .empty)
        XCTAssertEqual(prepared.first?.2, controller.preparationContextID)
        XCTAssertFalse(controller.canSend, "Voice requires a durable typed-batch record")
        controller.send()
        XCTAssertNotNil(controller.recoveryStatus); XCTAssertEqual(provider.submissions, 0)
    }

    // Catches including exactly half a second, empty PCM, or an over-limit recording.
    func testReferenceMinimumAndPreparationBoundsRefuseBeforeComposerTransfer() {
        var prepared = 0
        for count in [0, 24_000, 24_001, 24_959, 28_800_001] {
            let controller = TelegramUploadController()
            controller.bind(provider: VoiceControllerProvider())
            controller.didPrepare = { _, _, _ in prepared += 1 }
            defer { controller.clear() }
            let samples = [Int16](repeating: 0, count: count)
            XCTAssertFalse(controller.prepareRecordedVoice(samples: samples, target: target))
            XCTAssertEqual(controller.phase, .idle); XCTAssertNil(controller.preparationContextID)
            XCTAssertTrue(controller.items.isEmpty)
        }
        XCTAssertEqual(prepared, 0)
    }

    func testFirstCompletePacketAboveReferenceMinimumRetainsIntegralWireDurationZero() async throws {
        let controller = TelegramUploadController()
        controller.bind(provider: VoiceControllerProvider())
        defer { controller.clear() }
        XCTAssertTrue(controller.prepareRecordedVoice(samples: pulse(count: 24_960), target: target))
        try await settled(controller)
        let voice = try XCTUnwrap(controller.file?.metadata?.voice)
        XCTAssertEqual(voice.sampleCount, 24_960); XCTAssertEqual(voice.duration, 0)
    }

    // Catches accepting a different account, a legacy single-file provider, or
    // replacing the active recording before its first worker completes.
    func testAdmissionUsesAccountBoundBatchCapabilityAndPreservesActiveRequest() async throws {
        let controller = TelegramUploadController(), provider = VoiceControllerProvider()
        let pcm = pulse(count: 24_960)
        controller.bind(provider: nil)
        XCTAssertFalse(controller.prepareRecordedVoice(samples: pcm, target: target))
        controller.bind(provider: VoiceControllerSingleProvider())
        XCTAssertFalse(controller.prepareRecordedVoice(samples: pcm, target: target))
        controller.bind(provider: provider)
        XCTAssertFalse(controller.prepareRecordedVoice(samples: pcm,
            target: .init(accountID: 2, chatID: 42, title: "Different account")))
        XCTAssertTrue(controller.prepareRecordedVoice(samples: pcm, target: target))
        let id = controller.preparationContextID
        XCTAssertFalse(controller.prepareRecordedVoice(samples: pcm,
            target: .init(accountID: 1, chatID: 43, title: "Different chat")))
        XCTAssertEqual(controller.preparationContextID, id); XCTAssertEqual(controller.target, target)
        try await settled(controller)
        controller.clear()
    }

    // The preparation callback may synchronously cancel or replace an account.
    // Neither action may launch an orphan codec worker or resurrect its old stage.
    func testSynchronousCancellationAndRebindingStopBeforeWorkerLaunch() async throws {
        for rebind in [false, true] {
            let controller = TelegramUploadController()
            controller.bind(provider: VoiceControllerProvider())
            var finished: [UUID] = []
            controller.didFinishPreparation = { finished.append($0) }
            controller.didPrepare = { _, _, id in
                if rebind { controller.bind(provider: nil) }
                else { controller.dismissPreparation(contextID: id) }
            }
            XCTAssertFalse(controller.prepareRecordedVoice(samples: pulse(count: 24_960), target: target))
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(controller.phase, .idle); XCTAssertTrue(controller.items.isEmpty)
            XCTAssertNil(controller.preparationContextID); XCTAssertEqual(finished.count, 1)
        }
    }

    // Catches turning a valid voice into an invalid captioned preparation through
    // either the rich-input API or its compatibility string setter.
    func testRecordedVoiceRefusesCaptionAndMediaMutations() async throws {
        let controller = TelegramUploadController()
        controller.bind(provider: VoiceControllerProvider())
        defer { controller.clear() }
        XCTAssertTrue(controller.prepareRecordedVoice(samples: pulse(count: 24_960), target: target))
        try await settled(controller)
        let revision = controller.captionRevision, context = controller.captionContextID
        XCTAssertFalse(controller.updateCaptionInput(try .init(formattedText: .init(text: "Forbidden")), contextID: context))
        controller.caption = "Also forbidden"
        XCTAssertEqual(controller.captionInput, .empty); XCTAssertEqual(controller.captionRevision, revision)
        XCTAssertFalse(controller.updateCaptionPlacement(true, contextID: context, revision: revision))
        XCTAssertFalse(controller.updateMediaSpoiler(true, contextID: context, revision: revision))
        XCTAssertFalse(controller.updateGrouping(true, contextID: try XCTUnwrap(controller.preparationContextID), revision: controller.itemsRevision))
        XCTAssertFalse(controller.captionAboveMedia); XCTAssertFalse(controller.mediaSpoiler)
        XCTAssertTrue(controller.updateCaptionInput(.empty, contextID: context))
    }

    // Catches a compatibility setter poisoning the frozen voice caption before
    // the worker has published typed metadata for the new stage.
    func testVoiceProhibitsCaptionBeforeEncodingFinishes() async throws {
        let controller = TelegramUploadController()
        controller.bind(provider: VoiceControllerProvider())
        defer { controller.clear() }
        controller.didPrepare = { _, _, _ in controller.caption = "Too early" }
        XCTAssertTrue(controller.prepareRecordedVoice(samples: pulse(count: 24_960), target: target))
        XCTAssertEqual(controller.captionInput, .empty)
        try await settled(controller)
        XCTAssertEqual(controller.captionInput, .empty)
    }

    // Catches retaining a cancelled voice's caption restriction or resurrecting
    // its stage when the already scheduled codec task observes cancellation.
    func testCancellationReleasesVoiceRestrictionAndAllowsANewRecording() async throws {
        let controller = TelegramUploadController(), provider = VoiceControllerProvider()
        controller.bind(provider: provider)
        defer { controller.clear() }
        var finished = 0
        controller.didFinishPreparation = { _ in finished += 1 }
        XCTAssertTrue(controller.prepareRecordedVoice(samples: pulse(count: 24_960), target: target))
        controller.cancelPreparation()
        controller.caption = "An ordinary preparation may have a caption"
        XCTAssertEqual(controller.caption, "An ordinary preparation may have a caption")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.phase, .cancelled); XCTAssertTrue(controller.items.isEmpty)
        XCTAssertNil(controller.preparationContextID); XCTAssertEqual(finished, 1)
        XCTAssertEqual(provider.submissions, 0)
        XCTAssertTrue(controller.prepareRecordedVoice(samples: pulse(count: 24_960), target: target))
        try await settled(controller)
        XCTAssertEqual(controller.items.count, 1); XCTAssertEqual(controller.captionInput, .empty)
    }

    private func pulse(count: Int) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: count)
        for index in 0..<100 { pcm[index] = 1_000 }
        return pcm
    }
    private func settled(_ controller: TelegramUploadController) async throws {
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
    }
}

@MainActor private class VoiceControllerSingleProvider: TelegramUploadProvider {
    let accountID: Int64 = 1
    var submissions = 0
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
                caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        submissions += 1; receive(.rejected); return VoiceControllerLease()
    }
}
@MainActor private final class VoiceControllerProvider: VoiceControllerSingleProvider, TelegramUploadBatchProvider {
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        submissions += 1; receive(.rejected); return VoiceControllerLease()
    }
}
@MainActor private final class VoiceControllerLease: TelegramUploadLease { func stop() {} }
