import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramUploadControllerTests: XCTestCase {
    private final class Lease: TelegramUploadLease {
        var stops = 0
        func stop() { stops += 1 }
    }
    private final class Provider: TelegramUploadProvider {
        let accountID: Int64 = 1
        var callbacks: [@MainActor (TelegramUploadEvent) -> Void] = []
        var leases: [Lease] = []
        var targets: [TelegramUploadTarget] = []
        var captions: [String] = []
        var formattedCaptions: [TelegramFormattedText] = []
        var synchronous: [TelegramUploadEvent] = []
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, caption: TelegramFormattedText,
                    receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
            let lease = Lease(); leases.append(lease); callbacks.append(receive)
            targets.append(target); captions.append(caption.text); formattedCaptions.append(caption)
            for event in synchronous { receive(event) }
            return lease
        }
    }
    private let recipient = TelegramUploadTarget(accountID: 1, chatID: 2, title: "Synthetic")
    private func fixture() -> TelegramUploadFile {
        TelegramUploadFile(id: UUID(), name: "fixture", size: 3, mode: .file, pixelWidth: nil,
                           pixelHeight: nil, url: URL(fileURLWithPath: "/synthetic/payload"),
                           directory: URL(fileURLWithPath: "/synthetic/stage"))
    }
    private func ready() async -> (TelegramUploadController, Provider) {
        let controller = TelegramUploadController(), provider = Provider(), file = fixture()
        controller.stage = { _, _ in file }; controller.discard = { _ in }
        controller.bind(provider: provider)
        controller.prepare(source: file.url, mode: .file, target: recipient, caption: "original")
        for _ in 0..<100 where controller.phase == .preparing { await Task.yield() }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(provider.callbacks.count, 0)
        return (controller, provider)
    }

    func testExplicitSendFreezesTargetCaptionAndQueuesOnlyOnce() async {
        let (controller, provider) = await ready()
        var queued: [(TelegramUploadTarget, String)] = []
        controller.didQueue = { queued.append(($0, $1.text)) }
        controller.send(); controller.send(); controller.caption = "edited"
        XCTAssertEqual(provider.callbacks.count, 1)
        XCTAssertEqual(provider.targets, [recipient]); XCTAssertEqual(provider.captions, ["original"])
        provider.callbacks[0](.progress(1))
        XCTAssertEqual(controller.phase, .storing)
        provider.callbacks[0](.committing)
        XCTAssertFalse(controller.canCancel)
        controller.cancelPreparation()
        XCTAssertEqual(controller.phase, .enqueuing)
        provider.callbacks[0](.accepted("local")); provider.callbacks[0](.accepted("duplicate"))
        XCTAssertEqual(controller.messageID, "local"); XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.1, "original"); XCTAssertEqual(controller.caption, "edited")
        XCTAssertNil(controller.file)
        provider.callbacks[0](.progress(2)); XCTAssertEqual(controller.phase, .queued(1))
        provider.callbacks[0](.progress(.nan)); XCTAssertEqual(controller.phase, .queued(nil))
        provider.callbacks[0](.queueFailed); XCTAssertEqual(controller.phase, .queueFailed)
    }

    func testRichCaptionFreezesEntitiesAndRejectsStaleEditorCallbacks() async throws {
        let (controller, provider) = await ready()
        let formatted = try TelegramFormattedText(text: "e\u{301} 😀 caption",entities: [
            .init(offset: 0,length: 2,kind: .bold), .init(offset: 3,length: 2,kind: .italic)
        ])
        let input = try TelegramComposerInput(formattedText: formatted,selection: .init(location: 3,length: 2))
        let context = controller.captionContextID
        XCTAssertFalse(controller.updateCaptionInput(input,contextID: UUID()))
        XCTAssertTrue(controller.updateCaptionInput(input,contextID: context))
        controller.caption = formatted.text
        XCTAssertEqual(controller.captionInput,input,"Same-text compatibility updates retain entities/selection")
        var queued: TelegramFormattedText?
        controller.didQueue = { _,caption in queued = caption }
        controller.send()
        XCTAssertEqual(provider.formattedCaptions,[formatted])
        XCTAssertFalse(controller.updateCaptionInput(.empty,contextID: context))
        controller.caption = "later"
        provider.callbacks[0](.committing); provider.callbacks[0](.accepted("rich"))
        XCTAssertEqual(queued,formatted)
        XCTAssertEqual(controller.caption,"later")
    }

    func testEmptyCaptionAllowedAndUnsupportedRichCaptionCannotReachProvider() async throws {
        let (controller,provider) = await ready()
        let unsupported = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "x",entities: [
            .init(offset: 0,length: 1,kind: .customEmoji(stickerPack: nil,fileID: 123))
        ]))
        XCTAssertTrue(controller.updateCaptionInput(unsupported,contextID: controller.captionContextID))
        XCTAssertFalse(controller.canSend); controller.send()
        XCTAssertTrue(provider.callbacks.isEmpty)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(controller.updateCaptionInput(.empty,contextID: controller.captionContextID))
        XCTAssertTrue(controller.canSend); controller.send()
        XCTAssertEqual(provider.formattedCaptions,[TelegramComposerInput.empty.formattedText])
    }

    func testDeadlineBeforeCommitStopsAndRejectsLateEvents() async {
        let (controller, provider) = await ready()
        controller.send(); controller.expireSubmission()
        XCTAssertEqual(controller.phase, .failed); XCTAssertEqual(provider.leases[0].stops, 1)
        provider.callbacks[0](.committing); provider.callbacks[0](.accepted("late"))
        XCTAssertNil(controller.messageID); XCTAssertFalse(controller.canSend)
    }

    func testDeadlineAfterCommitAllowsLateAcknowledgementWithoutResend() async {
        let (controller, provider) = await ready()
        var count = 0; controller.didQueue = { _, _ in count += 1 }
        controller.send(); provider.callbacks[0](.committing); controller.expireSubmission()
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertEqual(provider.leases[0].stops, 0)
        controller.send(); XCTAssertEqual(provider.callbacks.count, 1)
        provider.callbacks[0](.accepted("late"))
        XCTAssertEqual(controller.phase, .queued(nil)); XCTAssertEqual(count, 1)
    }

    func testSynchronousRejectionStopsReturnedLeaseAndSyncAcceptanceSurvives() async {
        let (controller, provider) = await ready()
        provider.synchronous = [.rejected]
        controller.send()
        XCTAssertEqual(controller.phase, .rejected); XCTAssertEqual(provider.leases[0].stops, 1)
        let (second, secondProvider) = await ready()
        secondProvider.synchronous = [.committing, .accepted("sync")]
        second.send()
        XCTAssertEqual(second.messageID, "sync"); XCTAssertEqual(secondProvider.leases[0].stops, 0)
        second.clear(); XCTAssertEqual(secondProvider.leases[0].stops, 1)
        XCTAssertNotNil(second.error)
    }

    func testCancelAndAccountChangeNeverRetargetOrAcceptStaleCallbacks() async {
        let (controller, provider) = await ready()
        controller.send(); controller.cancelPreparation()
        XCTAssertEqual(controller.phase, .cancelled); XCTAssertNil(controller.file)
        provider.callbacks[0](.committing); provider.callbacks[0](.accepted("stale"))
        XCTAssertNil(controller.messageID)
        let (second, secondProvider) = await ready()
        second.send(); secondProvider.callbacks[0](.committing)
        second.bind(provider: nil)
        XCTAssertNotNil(second.error); XCTAssertEqual(secondProvider.leases[0].stops, 1)
        secondProvider.callbacks[0](.accepted("old-account"))
        XCTAssertNil(second.messageID); XCTAssertFalse(second.canSend)
    }

    func testCaptionUTF16LimitAndCleanupFailureAreVisible() async {
        let (controller, provider) = await ready()
        controller.caption = String(repeating: "😀", count: 513)
        XCTAssertFalse(controller.canSend); controller.send()
        XCTAssertNotNil(controller.error); XCTAssertTrue(provider.callbacks.isEmpty)
        controller.discard = { _ in throw TelegramUploadFileError.stagingFailed }
        controller.cancelPreparation()
        XCTAssertNotNil(controller.error); XCTAssertNotNil(controller.file)
        controller.clear(); XCTAssertNotNil(controller.error); XCTAssertNotNil(controller.file)
    }
    func testCancelledStagingFinishesBeforeAnotherWorkerAndDiscardsLateFile() async {
        let controller = TelegramUploadController(), provider = Provider(), file = fixture()
        var continuation: CheckedContinuation<TelegramUploadFile, Never>?
        var starts = 0, discarded = 0
        controller.stage = { _, _ in
            starts += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        controller.discard = { _ in discarded += 1 }
        controller.bind(provider: provider)
        controller.prepare(source: file.url, mode: .file, target: recipient, caption: "caption")
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        controller.cancelPreparation()
        controller.prepare(source: file.url, mode: .file, target: recipient, caption: "other")
        XCTAssertEqual(starts, 1)
        continuation?.resume(returning: file)
        for _ in 0..<100 where discarded == 0 { await Task.yield() }
        XCTAssertEqual(discarded, 1); XCTAssertEqual(controller.phase, .cancelled)
        XCTAssertNil(controller.file); XCTAssertTrue(provider.callbacks.isEmpty)
    }

}
