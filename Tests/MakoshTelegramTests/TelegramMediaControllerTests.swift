import XCTest
@testable import MakoshTelegram

@MainActor
final class TelegramMediaControllerTests: XCTestCase {
    private final class Lease: TelegramMediaLease {
        var cancellations = 0
        var onCancel: (() -> Void)?
        func cancel() { cancellations += 1; onCancel?() }
    }
    private final class Provider: TelegramMediaProvider {
        var callbacks: [@MainActor (TelegramMediaEvent) -> Void] = []
        var leases: [Lease] = []
        var synchronous: [TelegramMediaEvent] = []
        func start(attachmentID: String, purpose: TelegramMediaPurpose,
                   receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            let lease = Lease()
            leases.append(lease); callbacks.append(receive)
            for event in synchronous { receive(event) }
            return lease
        }
    }
    private func attachment(name: String = "file", preview: Bool = true, full: Bool = true) -> TelegramAttachment {
        TelegramAttachment(id: "resource", kind: .file, name: name, byteCount: 8,
                           mimeType: "application/octet-stream", hasPreview: preview, canDownload: full)
    }
    private let key = TelegramMediaKey(attachmentID: "resource", purpose: .full)
    private let url = URL(fileURLWithPath: "/synthetic/resource")
    private func setup() -> (TelegramMediaController, Provider) {
        let controller = TelegramMediaController(), provider = Provider()
        controller.bind(provider: provider); controller.retain(attachments: [attachment()])
        return (controller, provider)
    }

    func testNoAutomaticFetchAndCapabilities() {
        let (controller, provider) = setup()
        XCTAssertEqual(provider.callbacks.count, 0)
        XCTAssertEqual(controller.phase(for: key), .idle)
        let blocked = attachment(preview: false, full: false)
        controller.retain(attachments: [blocked])
        controller.start(blocked, purpose: .preview); controller.start(blocked, purpose: .full)
        XCTAssertEqual(provider.callbacks.count, 0)
    }

    func testFullCompletionFreezesHandlerAndNeverCapturesPreviewOrStaleCallbacks() {
        let (controller,provider) = setup()
        var calls: [String] = []
        controller.completedFullFile = { id,_,size in calls.append("old:\(id):\(size)") }
        controller.start(attachment(),purpose: .full)
        controller.completedFullFile = { _,_,_ in calls.append("new") }
        provider.callbacks[0](.data(url,offset: 0,size: 8,complete: true))
        provider.callbacks[0](.data(url,offset: 0,size: 8,complete: true))
        XCTAssertEqual(calls,["old:resource:8"])
        controller.start(attachment(),purpose: .preview)
        provider.callbacks[1](.data(url,offset: 0,size: 8,complete: true))
        controller.reset()
        provider.callbacks[0](.data(url,offset: 0,size: 8,complete: true))
        XCTAssertEqual(calls,["old:resource:8"])
    }

    func testOnlyCompleteZeroOffsetDataBecomesReadyAndRetainsLease() {
        let (controller, provider) = setup()
        controller.start(attachment(), purpose: .full); controller.start(attachment(), purpose: .full)
        XCTAssertEqual(provider.callbacks.count, 1)
        provider.callbacks[0](.fetchCompleted)
        provider.callbacks[0](.data(url, offset: 1, size: 8, complete: true))
        provider.callbacks[0](.data(url, offset: 0, size: 8, complete: false))
        XCTAssertEqual(controller.phase(for: key), .downloading(nil))
        XCTAssertNil(controller.downloadedFile(for: key))
        provider.callbacks[0](.data(url, offset: 0, size: 8, complete: true))
        provider.callbacks[0](.failed); provider.callbacks[0](.progress(0.2))
        controller.timeout(key); controller.start(attachment(), purpose: .full)
        XCTAssertEqual(controller.phase(for: key), .ready)
        XCTAssertEqual(controller.downloadedFile(for: key), url)
        XCTAssertEqual(provider.leases[0].cancellations, 0)
        XCTAssertEqual(provider.callbacks.count, 1)
        controller.reset()
        XCTAssertEqual(provider.leases[0].cancellations, 1)
    }

    func testProgressIsFiniteAndClamped() {
        let (controller, provider) = setup()
        controller.start(attachment(), purpose: .full)
        for (input, expected) in [(-1.0, 0.0), (2.0, 1.0), (0.25, 0.25)] {
            provider.callbacks[0](.progress(input))
            XCTAssertEqual(controller.phase(for: key), .downloading(expected))
        }
        for input in [Double.nan, Double.infinity, -Double.infinity] {
            provider.callbacks[0](.progress(input))
            XCTAssertEqual(controller.phase(for: key), .downloading(nil))
        }
    }

    func testFailureCancelAndDeadlineInvalidateOldCallbacksAndPermitRetry() {
        let (controller, provider) = setup()
        for terminal in [TelegramMediaPhase.failed, .cancelled, .timedOut] {
            controller.start(attachment(), purpose: .full)
            let index = provider.callbacks.count - 1
            provider.leases[index].onCancel = { provider.callbacks[index](.data(self.url, offset: 0, size: 8, complete: true)) }
            switch terminal {
            case .failed: provider.callbacks[index](.failed)
            case .cancelled: controller.cancel(key)
            default: controller.timeout(key)
            }
            XCTAssertEqual(controller.phase(for: key), terminal)
            XCTAssertNil(controller.downloadedFile(for: key))
            XCTAssertEqual(provider.leases[index].cancellations, 1)
            controller.start(attachment(), purpose: .full)
            provider.callbacks[index](.failed)
            XCTAssertEqual(controller.phase(for: key), .downloading(nil))
            controller.cancel(key)
        }
    }

    func testRemovalResourceChangeAndAccountBindingCancelBothPurposes() {
        let (controller, provider) = setup()
        controller.start(attachment(), purpose: .preview); controller.start(attachment(), purpose: .full)
        controller.retain(attachments: [attachment()])
        XCTAssertEqual(provider.leases.map(\.cancellations), [0, 0])
        controller.retain(attachments: [attachment(name: "changed")])
        XCTAssertEqual(provider.leases.map(\.cancellations), [1, 1])
        XCTAssertEqual(controller.phase(for: key), .idle)
        controller.start(attachment(name: "changed"), purpose: .full)
        controller.bind(provider: Provider())
        provider.callbacks[2](.data(url, offset: 0, size: 8, complete: true))
        XCTAssertEqual(controller.phase(for: key), .idle)
        XCTAssertEqual(provider.leases[2].cancellations, 1)
        controller.reset()
        XCTAssertEqual(provider.leases[2].cancellations, 1)
    }

    func testSynchronousCompletionAndFailureHandleReturnedLease() {
        let (controller, provider) = setup()
        provider.synchronous = [.data(url, offset: 0, size: 8, complete: true), .failed]
        controller.start(attachment(), purpose: .full)
        XCTAssertEqual(controller.phase(for: key), .ready)
        XCTAssertEqual(provider.leases[0].cancellations, 0)
        controller.cancel(key)
        provider.synchronous = [.failed]
        controller.start(attachment(), purpose: .full)
        XCTAssertEqual(controller.phase(for: key), .failed)
        XCTAssertEqual(provider.leases[1].cancellations, 1)
    }

    func testBorrowSurvivesResetAndReleasesExactlyOnce() async throws {
        let (controller, provider) = setup()
        controller.start(attachment(), purpose: .full)
        provider.callbacks[0](.data(url, offset: 0, size: 8, complete: true))
        let borrowed = try await controller.withDownloadedFile(for: key) { file, size in
            XCTAssertEqual(file, self.url); XCTAssertEqual(size, 8)
            controller.reset(); controller.reset(); controller.cancel(self.key)
            await Task.yield()
            XCTAssertEqual(provider.leases[0].cancellations, 0)
        }
        XCTAssertTrue(borrowed)
        XCTAssertEqual(provider.leases[0].cancellations, 1)
        let unavailable = try await controller.withDownloadedFile(for: key) { _, _ in XCTFail("Removed file") }
        XCTAssertFalse(unavailable)
    }
}
