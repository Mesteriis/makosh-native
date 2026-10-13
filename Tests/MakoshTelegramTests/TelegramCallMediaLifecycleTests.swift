import XCTest
import CoreVideo
@testable import MakoshTelegram

@MainActor final class TelegramCallMediaLifecycleTests: XCTestCase {
    func testStopJoinsNativeDeviceAndCameraReleaseBeforeAcknowledging() async {
        let core = CallCoreFixture(), camera = CallCameraFixture(), events = CallMediaEvents()
        let media = TelegramCallMediaSession(makeCore: { inbox in core.inbox = inbox; return core }, makeCamera: { camera }, video: true, receive: events.receive)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(camera.starts, 1)
        var released = 0; media.stop { released += 1 }
        XCTAssertEqual(core.stops, 1); XCTAssertEqual(camera.stops, 1); XCTAssertEqual(released, 0)
        core.inbox?.release(); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(released, 0)
        camera.release?(); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(released, 1)
        XCTAssertFalse(media.setMuted(false)); let enabled = await media.setVideo(true); XCTAssertFalse(enabled)
    }
    func testNativeStateIsRequiredForConnectionAndRevocationRejectsLateFrames() async {
        let core = CallCoreFixture(), camera = CallCameraFixture(), events = CallMediaEvents()
        let media = TelegramCallMediaSession(makeCore: { inbox in core.inbox = inbox; return core }, makeCamera: { camera }, video: false, receive: events.receive)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(camera.starts, 0); XCTAssertEqual(events.connected, 0)
        core.inbox?.enqueue(.state(2)); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(events.connected, 1)
        media.stop {}
        XCTAssertFalse(core.inbox?.enqueue(.state(2)) ?? true)
        core.inbox?.release(); for _ in 0..<20 { await Task.yield() }
    }
    func testRepeatedNativeEstablishedStateDoesNotReconnectOrStopAValidCall() async {
        let core = CallCoreFixture(), camera = CallCameraFixture(), events = CallMediaEvents()
        let media = TelegramCallMediaSession(makeCore: { inbox in core.inbox = inbox; return core }, makeCamera: { camera }, video: false, receive: events.receive)
        core.inbox?.enqueue(.state(2)); core.inbox?.enqueue(.state(2))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(events.connected, 1); XCTAssertEqual(core.stops, 0)
        media.stop {}; core.inbox?.release(); for _ in 0..<20 { await Task.yield() }
    }
    func testLateCameraFrameCannotReturnAfterVideoWasDisabled() async throws {
        let core = CallCoreFixture(), camera = CallCameraFixture(), events = CallMediaEvents()
        let media = TelegramCallMediaSession(makeCore: { inbox in core.inbox = inbox; return core }, makeCamera: { camera }, video: true, receive: events.receive)
        await fulfillment(of: [camera.started], timeout: 2)
        let disabled = Task { await media.setVideo(false) }
        await fulfillment(of: [camera.stopped], timeout: 2)
        var frame: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &frame), kCVReturnSuccess)
        camera.output?(try XCTUnwrap(frame)); camera.release?()
        let result = await disabled.value; XCTAssertTrue(result)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(events.localFrames, 0)
        media.stop {}; core.inbox?.release()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    func testCameraFailureEndsMediaAndNeverReportsConnected() async {
        let core = CallCoreFixture(), camera = CallCameraFixture(), events = CallMediaEvents(); camera.succeeds = false
        let media = TelegramCallMediaSession(makeCore: { inbox in core.inbox = inbox; return core }, makeCamera: { camera }, video: true, receive: events.receive)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(events.failures, 1); XCTAssertEqual(events.connected, 0)
        XCTAssertEqual(core.stops, 1)
        core.inbox?.release(); camera.release?(); for _ in 0..<20 { await Task.yield() }
        withExtendedLifetime(media) {}
    }
}
@MainActor private final class CallMediaEvents {
    var connected = 0, failures = 0, localFrames = 0
    func receive(_ event: TelegramCallMediaEvent) -> Bool {
        switch event { case .transportConnected: connected += 1; case .failed: failures += 1; case .localVideoFrame: localFrames += 1; default: break }; return true
    }
}
@MainActor private final class CallCoreFixture: TelegramCallNativeBridge {
    var inbox: TelegramCallMediaInbox?, stops = 0
    var videoOutput: @Sendable (CVPixelBuffer) -> Void { { _ in } }
    func stop() { stops += 1 }
    func setMuted(_ value: Bool) -> Bool { true }
    func setVideo(_ value: Bool) -> Bool { true }
    func receive(_ data: Data) -> Bool { true }
}
@MainActor private final class CallCameraFixture: TelegramCallCameraSource {
    var starts = 0, stops = 0, succeeds = true
    let started = XCTestExpectation(description: "Camera start requested")
    let stopped = XCTestExpectation(description: "Camera stop requested")
    var output: (@Sendable (CVPixelBuffer) -> Void)?
    var release: (@MainActor () -> Void)?
    func start(output: @escaping @Sendable (CVPixelBuffer) -> Void, failure: @escaping @MainActor () -> Void) async -> Bool { starts += 1; self.output = output; started.fulfill(); return succeeds }
    func stop(completed: @escaping @MainActor () -> Void) { stops += 1; release = completed; stopped.fulfill() }
}
