import XCTest
import Foundation
import Combine
import TelegramCore
import Postbox
@testable import MakoshTelegram

private nonisolated func playbackEmojiDescriptor() throws -> TelegramCustomEmojiDescriptor {
    let file = TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: 100), partialReference: nil,
        resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 100, accessHash: 53,
            size: 36, fileReference: Data([1, 2]), fileName: "synthetic-emoji.webp"),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/webp", size: 36,
        attributes: [.CustomEmoji(isPremium: false, isSingleColor: false, alt: "🦊", packReference: nil)],
        alternativeRepresentations: [])
    return try TelegramCustomEmojiDescriptor(file: file)
}
@MainActor final class TelegramCustomEmojiPlaybackTests: XCTestCase {
    private final class Lease: TelegramMediaLease {
        var cancelled = false
        var onCancel: (() -> Void)?
        func cancel() { guard !cancelled else { return }; cancelled = true; onCancel?() }
    }
    private final class Provider: TelegramCustomEmojiResourceProvider {
        let accountID: Int64
        var callbacks: [@MainActor (TelegramMediaEvent) -> Void] = []
        var leases: [Lease] = []
        var synchronous: [TelegramMediaEvent] = []
        init(accountID: Int64 = 1) { self.accountID = accountID }
        func start(descriptor: TelegramCustomEmojiDescriptor,
            receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            let lease = Lease(); leases.append(lease); callbacks.append(receive)
            for event in synchronous { receive(event) }
            return lease
        }
    }
    private func fixture(bytes: Data = UploadWebPFixture.small.data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-emoji-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("synthetic.webp")
        try bytes.write(to: file)
        return file
    }
    private func setup(deadline: Duration = .seconds(30)) -> (TelegramCustomEmojiPlaybackController, TelegramCustomEmojiPlaybackContext, Provider) {
        let provider = Provider(), controller = TelegramCustomEmojiPlaybackController(loadingDeadline: deadline)
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        controller.bind(context: context)
        return (controller, context, provider)
    }

    // Catches a text-only placeholder path and releasing the native cache keep
    // lease while a successfully decoded emoji is still visible.
    func testCompleteSyntheticResourceProducesRealPixelsAndKeepsLeaseUntilStop() async throws {
        let (controller, _, provider) = setup(), url = try fixture()
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        XCTAssertEqual(controller.phase, .loading)
        guard provider.callbacks.count == 1 else { XCTFail("No account resource request"); return }
        let ready = expectation(description: "real frame")
        let token = controller.$frame.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        provider.callbacks[0](.data(url, offset: 0, size: 36, complete: true))
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(token) {}
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(controller.frame?.pixels.prefix(4), Data([0, 0, 255, 255]))
        XCTAssertFalse(provider.leases[0].cancelled)
        controller.stop()
        XCTAssertNil(controller.frame); XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(provider.leases[0].cancelled)
    }

    // Catches late complete-data/decoder callbacks from an old account showing
    // their image after the view bound to a new account context.
    func testContextInvalidationCancelsResourceAndRefusesLatePixels() async throws {
        let (controller, context, provider) = setup(), url = try fixture()
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        guard provider.callbacks.count == 1 else { XCTFail("No account resource request"); return }
        context.invalidate()
        XCTAssertTrue(provider.leases[0].cancelled)
        let late = expectation(description: "old frame must not publish"); late.isInverted = true
        let token = controller.$frame.compactMap { $0 }.sink { _ in late.fulfill() }
        provider.callbacks[0](.data(url, offset: 0, size: 36, complete: true))
        await fulfillment(of: [late], timeout: 0.1)
        withExtendedLifetime(token) {}
        XCTAssertNil(controller.frame); XCTAssertEqual(controller.phase, .idle)
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        XCTAssertEqual(provider.callbacks.count, 1)
    }

    // Catches synchronous provider completion racing lease assignment and a
    // failure/cancellation callback erasing an already published good frame.
    func testSynchronousCompleteDataIsOwnedBeforeLateFailure() async throws {
        let (controller, _, provider) = setup(), url = try fixture()
        provider.synchronous = [.data(url, offset: 0, size: 36, complete: true)]
        let ready = expectation(description: "synchronous source real frame")
        let token = controller.$frame.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(token) {}
        guard provider.callbacks.count == 1 else { XCTFail("No account resource request"); return }
        let frame = controller.frame
        provider.callbacks[0](.failed)
        XCTAssertEqual(controller.frame, frame); XCTAssertEqual(controller.phase, .playing)
        XCTAssertFalse(provider.leases[0].cancelled)
        controller.stop(); XCTAssertTrue(provider.leases[0].cancelled)
    }

    // Catches unbounded pending network leases and accepting a stale data event
    // after its loading deadline released the account resource.
    func testLoadingDeadlineCancelsLeaseAndKeepsUnicodeFallback() async throws {
        let (controller, _, provider) = setup(deadline: .milliseconds(20)), url = try fixture()
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        guard provider.callbacks.count == 1 else { XCTFail("No account resource request"); return }
        let timedOut = expectation(description: "bounded resource deadline")
        let token = controller.$phase.filter { $0 == .failed }.prefix(1).sink { _ in timedOut.fulfill() }
        await fulfillment(of: [timedOut], timeout: 3)
        withExtendedLifetime(token) {}
        XCTAssertTrue(provider.leases[0].cancelled); XCTAssertNil(controller.frame)
        provider.callbacks[0](.data(url, offset: 0, size: 36, complete: true))
        XCTAssertEqual(controller.phase, .failed); XCTAssertNil(controller.frame)
    }

    // Catches rebinding only UI state while an old account lease or worker
    // can still overwrite the new account's current preview.
    func testRebindCancelsOldAccountAndOnlyNewContextCanPublish() async throws {
        let (controller, _, old) = setup(), url = try fixture()
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        guard old.callbacks.count == 1 else { XCTFail("No old account request"); return }
        let fresh = Provider(accountID: 2)
        let context = TelegramCustomEmojiPlaybackContext(accountID: 2, provider: fresh)
        controller.bind(context: context)
        XCTAssertTrue(old.leases[0].cancelled)
        old.callbacks[0](.failed)
        XCTAssertEqual(controller.phase, .idle); XCTAssertNil(controller.frame)
        let ready = expectation(description: "new context real frame")
        let token = controller.$frame.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        guard fresh.callbacks.count == 1 else { XCTFail("No new account request"); return }
        old.callbacks[0](.data(url, offset: 0, size: 36, complete: true))
        fresh.callbacks[0](.data(url, offset: 0, size: 36, complete: true))
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(token) {}
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(controller.frame?.pixels.prefix(4), Data([0, 0, 255, 255]))
        controller.stop()
    }

    // Catches a page of distinct visible emoji retaining unlimited native
    // fetch/decode leases, or failing to return budget on disappearing views.
    func testAccountContextCapsVisibleLeasesAndReleasesBudgetOnStop() throws {
        let provider = Provider()
        let matched = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider,
            limits: .init(maximumVisibleLeases: 2, maximumAnimatedDecoders: 1, maximumEncodedBytes: 1024))
        let controllers = (0..<3).map { _ in TelegramCustomEmojiPlaybackController() }
        let descriptor = try playbackEmojiDescriptor()
        for controller in controllers { controller.bind(context: matched); controller.play(descriptor: descriptor, width: 20, height: 10) }
        XCTAssertEqual(provider.callbacks.count, 2)
        XCTAssertEqual(controllers[2].phase, .failed)
        controllers[0].stop()
        controllers[2].play(descriptor: descriptor, width: 20, height: 10)
        XCTAssertEqual(provider.callbacks.count, 3)
        XCTAssertEqual(controllers[2].phase, .loading)
        for controller in controllers { controller.stop() }
        let mismatch = TelegramCustomEmojiPlaybackContext(accountID: 2, provider: provider)
        controllers[0].bind(context: mismatch)
        controllers[0].play(descriptor: descriptor, width: 20, height: 10)
        XCTAssertEqual(provider.callbacks.count, 3)
        XCTAssertEqual(controllers[0].phase, .failed)
    }

    // Characterizes the real animated decoder budget: a second file retains
    // Unicode until the cancelled first worker actually releases its slot.
    func testAnimatedDecoderBudgetIsReleasedOnlyAfterCancelledWorkerEnds() async throws {
        try await checkAnimatedBudget(maximumAnimatedDecoders: 1, encodedFiles: 3)
    }

    // Characterizes aggregate encoded-byte admission with real animated bytes;
    // decoder slots remain available, so only the encoded-byte cap can refuse.
    func testEncodedByteBudgetRejectsSecondAnimationAndReturnsAfterStop() async throws {
        try await checkAnimatedBudget(maximumAnimatedDecoders: 3, encodedFiles: 1)
    }

    private func checkAnimatedBudget(maximumAnimatedDecoders: Int, encodedFiles: Int) async throws {
        let bytes = UploadWebPFixture.animated.data, url = try fixture(bytes: bytes), provider = Provider()
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider,
            limits: .init(maximumVisibleLeases: 3, maximumAnimatedDecoders: maximumAnimatedDecoders,
                maximumEncodedBytes: bytes.count * encodedFiles))
        let first = TelegramCustomEmojiPlaybackController(), second = TelegramCustomEmojiPlaybackController()
        defer { first.stop(); second.stop() }
        let descriptor = try playbackEmojiDescriptor()
        first.bind(context: context); second.bind(context: context)
        first.play(descriptor: descriptor, width: 40, height: 20)
        second.play(descriptor: descriptor, width: 40, height: 20)
        guard provider.callbacks.count == 2 else { XCTFail("Both visible resources must be requested"); return }
        let firstReady = expectation(description: "first actual animated frame")
        let firstToken = first.$frame.compactMap { $0 }.prefix(1).sink { _ in firstReady.fulfill() }
        provider.callbacks[0](.data(url, offset: 0, size: Int64(bytes.count), complete: true))
        await fulfillment(of: [firstReady], timeout: 3)
        withExtendedLifetime(firstToken) {}
        guard first.phase == .playing else { XCTFail("A real animation must hold its budget"); return }
        provider.callbacks[1](.data(url, offset: 0, size: Int64(bytes.count), complete: true))
        XCTAssertEqual(second.phase, .failed); XCTAssertNil(second.frame); XCTAssertTrue(provider.leases[1].cancelled)
        let released = expectation(description: "cancelled native worker releases borrowed resource")
        provider.leases[0].onCancel = { released.fulfill() }
        first.stop()
        await fulfillment(of: [released], timeout: 3)
        second.play(descriptor: descriptor, width: 40, height: 20)
        guard provider.callbacks.count == 3 else { XCTFail("Explicit retry must acquire a fresh resource"); return }
        let secondReady = expectation(description: "released budget permits actual new pixels")
        let secondToken = second.$frame.compactMap { $0 }.prefix(1).sink { _ in secondReady.fulfill() }
        provider.callbacks[2](.data(url, offset: 0, size: Int64(bytes.count), complete: true))
        await fulfillment(of: [secondReady], timeout: 3)
        withExtendedLifetime(secondToken) {}
        XCTAssertEqual(second.phase, .playing); XCTAssertNotNil(second.frame)
    }

    // Catches using reported completion without checking byte bounds, and a
    // malformed file replacing source Unicode with invisible/broken pixels.
    func testOversizedReportedResourceAndMalformedBytesNeverPublishFrame() async throws {
        let (controller, _, provider) = setup(), url = try fixture()
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        guard provider.callbacks.count == 1 else { XCTFail("No account resource request"); return }
        provider.callbacks[0](.data(url, offset: 0, size: 8 * 1024 * 1024 + 1, complete: true))
        XCTAssertEqual(controller.phase, .failed); XCTAssertNil(controller.frame)
        XCTAssertTrue(provider.leases[0].cancelled)
        try Data([0, 1, 2]).write(to: url)
        let rejected = expectation(description: "actual invalid bytes rejected")
        controller.stop()
        let token = controller.$phase.filter { $0 == .failed }.prefix(1).sink { _ in rejected.fulfill() }
        controller.play(descriptor: try playbackEmojiDescriptor(), width: 20, height: 10)
        guard provider.callbacks.count == 2 else { XCTFail("No retry resource request"); return }
        provider.callbacks[1](.data(url, offset: 0, size: 3, complete: true))
        await fulfillment(of: [rejected], timeout: 3)
        withExtendedLifetime(token) {}
        XCTAssertNil(controller.frame); XCTAssertTrue(provider.leases[1].cancelled)
    }
}
