import XCTest
import AVFoundation
@testable import MakoshTelegram

@MainActor final class TelegramRoundVideoCaptureTests: XCTestCase {
    // Catches constructing device inputs while either independently required grant is absent.
    func testBothAuthorizationStatusesGateBeforeCreatingSource() async throws {
        for pair: (AVAuthorizationStatus,AVAuthorizationStatus) in [(.authorized,.denied),(.notDetermined,.authorized),(.restricted,.authorized)] {
            var created = false
            let capture = TelegramCameraRoundVideoCapture(authorization: { pair }, makeSource: { created = true; return SyntheticRoundSource() })
            do { try await capture.start(); XCTFail("Unauthorized capture started") }
            catch { XCTAssertEqual(error as? TelegramRoundVideoCaptureError, .permissionDenied) }
            XCTAssertFalse(created); XCTAssertFalse(capture.isRecording); XCTAssertNil(capture.previewSession)
        }
    }
    // Catches start reporting success before both actual writer formats can be used.
    func testStartWaitsForActualSamplesAndStopReturnsValidatedData() async throws {
        let source = SyntheticRoundSource()
        let capture = TelegramCameraRoundVideoCapture(authorization: { (.authorized,.authorized) }, makeSource: { source })
        do {
            try await capture.start(); XCTAssertTrue(capture.isRecording)
            XCTAssertEqual(capture.duration, 1, accuracy: 0.001)
            let bytes = try await capture.stop()
            XCTAssertFalse(capture.isRecording)
            let retained = try await capture.stop(); XCTAssertEqual(retained, bytes)
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
            defer { try? TelegramUploadFileIO.discard(file) }
            XCTAssertEqual(file.video?.width, 300)
        } catch { XCTFail("Synthetic native capture refused: \(error)") }
    }
    // Catches indefinite warmup and a cancelled startup resurrecting via delayed source delivery.
    func testMissingFormatsTimeoutAndCancellationAreTerminal() async throws {
        for cancel in [false,true] {
            let source = SyntheticRoundSource(); source.feeds = false
            let capture = TelegramCameraRoundVideoCapture(authorization: { (.authorized,.authorized) }, makeSource: { source }, startupTimeout: 0.05)
            let start = Task { try await capture.start() }
            if cancel { for _ in 0..<10 { await Task.yield() }; capture.cancel() }
            do { try await start.value; XCTFail("Unready capture started") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } else { XCTAssertEqual(error as? TelegramRoundVideoCaptureError, .unavailable) } }
            XCTAssertFalse(capture.isRecording)
            do { _ = try await capture.stop(); XCTFail("Terminal capture returned bytes") } catch {}
            XCTAssertNil(capture.previewSession)
        }
    }
    // Catches waiting for an uncooperative source task before enforcing the startup deadline.
    func testHeldSourceStartIsBoundedAndLateCompletionCannotReviveCapture() async throws {
        for cancelled in [false,true] {
            let source = HeldRoundSource()
            let capture = TelegramCameraRoundVideoCapture(authorization: { (.authorized,.authorized) },
                makeSource: { source }, startupTimeout: 0.3)
            let start = Task { try await capture.start() }
            for _ in 0..<200 where !source.held { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(source.held)
            if cancelled { capture.cancel() }
            do { try await start.value; XCTFail("Held source bypassed startup boundary") }
            catch { if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? TelegramRoundVideoCaptureError, .unavailable) } }
            source.release()
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(source.completed)
            XCTAssertTrue(source.stopped)
            XCTAssertFalse(capture.isRecording); XCTAssertNil(capture.previewSession)
            do { _ = try await capture.stop(); XCTFail("Late startup resurrected recording") } catch {}
        }
    }
    // Catches a source/audio stall leaving native capture active without a bounded watchdog.
    func testCaptureWatchdogStopsSourceAndRetainsCompletedBytes() async throws {
        let source = SyntheticRoundSource()
        let capture = TelegramCameraRoundVideoCapture(authorization: { (.authorized,.authorized) }, makeSource: { source }, captureTimeout: 0.05)
        do {
            try await capture.start()
            for _ in 0..<100 where capture.isRecording { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(capture.isRecording)
            let bytes = try await capture.stop(); XCTAssertFalse(bytes.isEmpty)
            XCTAssertTrue(source.stopped)
        } catch { XCTFail("Watchdog lost recording: \(error)") }
    }
    // Catches a stopped audio stream waiting the full60s while video capture remains active.
    func testAudioStallWatchdogFinalizesLastValidSamples() async throws {
        let source = SyntheticRoundSource()
        let capture = TelegramCameraRoundVideoCapture(authorization: { (.authorized,.authorized) }, makeSource: { source }, audioStallTimeout: 0.05)
        do {
            try await capture.start()
            for _ in 0..<100 where capture.isRecording { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(capture.isRecording)
            let bytes = try await capture.stop(); XCTAssertFalse(bytes.isEmpty)
            XCTAssertTrue(source.stopped)
        } catch { XCTFail("Audio stall lost valid recording: \(error)") }
    }
    // Cancelling a source's in-flight async append cancels the real native writer.
    // Normal stop must drain that append and retain an admissible recording.
    func testStopDrainsInFlightSampleBeforeFinishingRecording() async throws {
        try await drainsInFlightSample(automatic: false)
    }
    func testWatchdogDrainsInFlightSampleBeforeRetainingRecording() async throws {
        try await drainsInFlightSample(automatic: true)
    }
    private func drainsInFlightSample(automatic: Bool) async throws {
        let source = InFlightRoundSource()
        let capture = TelegramCameraRoundVideoCapture(authorization: { (.authorized,.authorized) },
            makeSource: { source }, captureTimeout: automatic ? 0.1 : 60)
        defer { capture.cancel(); source.cancel() }
        try await capture.start()
        source.holdNextAppend()
        for _ in 0..<200 where !source.entered { try await Task.sleep(for: .milliseconds(5)) }
        guard source.entered else { return XCTFail("Actual writer append was not entered") }
        if automatic {
            for _ in 0..<200 where capture.isRecording { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(capture.isRecording)
        }
        do {
            let bytes = try await capture.stop()
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
            defer { try? TelegramUploadFileIO.discard(file) }
            XCTAssertEqual(file.video?.width, 300)
            XCTAssertEqual(try XCTUnwrap(file.video).duration, 2, accuracy: 0.001)
            let retained = try await capture.stop(); XCTAssertEqual(retained, bytes)
        } catch { XCTFail("Graceful stop cancelled valid in-flight recording: \(error)") }
    }
    // Catches reusing a cancelled one-shot capture, or public construction touching a device.
    func testPublicConstructionIsInertAndCancelCannotBeReused() async throws {
        let capture = try TelegramCameraRoundVideoCapture()
        XCTAssertNil(capture.previewSession); XCTAssertFalse(capture.isRecording)
        capture.cancel()
        do { try await capture.start(); XCTFail("Cancelled capture restarted") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor private final class InFlightRoundSource: TelegramRoundVideoCaptureSource {
    var previewSession: AVCaptureSession? { nil }
    private var writer: TelegramRoundVideoCaptureWriter?
    private var operation: Task<Void, any Error>?
    private let gate = DispatchSemaphore(value: 0)
    private(set) var entered = false
    func start(writer: TelegramRoundVideoCaptureWriter) async throws {
        self.writer = writer; try await roundCaptureFeed(writer)
    }
    func holdNextAppend() {
        guard let writer else { return }
        let gate = gate
        writer.sampleQueue.async { _ = gate.wait(timeout: .now() + 5) }
        operation = Task {
            entered = true
            try await writer.appendVideo(roundCapturePixels(), at: CMTime(value: 1, timescale: 1))
            try await writer.appendAudio(roundCaptureAudio(offset: 44_100, count: 44_100))
        }
    }
    func stop() async { gate.signal(); _ = try? await operation?.value; operation = nil }
    func cancel() { operation?.cancel(); gate.signal(); operation = nil }
}

@MainActor private final class SyntheticRoundSource: TelegramRoundVideoCaptureSource {
    var previewSession: AVCaptureSession? { nil }
    var feeds = true, stopped = false
    func start(writer: TelegramRoundVideoCaptureWriter) async throws { if feeds { try await roundCaptureFeed(writer) } }
    func stop() async { stopped = true }
    func cancel() { stopped = true }
}

@MainActor private final class HeldRoundSource: TelegramRoundVideoCaptureSource {
    var previewSession: AVCaptureSession? { nil }
    var held = false, completed = false, stopped = false
    private var continuation: CheckedContinuation<Void, Never>?
    func start(writer: TelegramRoundVideoCaptureWriter) async throws {
        try await writer.appendVideo(roundCapturePixels(), at: .zero)
        try await writer.appendAudio(roundCaptureAudio(offset: 0, count: 1470))
        await withCheckedContinuation { continuation = $0; held = true }
        completed = true
    }
    func release() { let saved = continuation; continuation = nil; saved?.resume() }
    func stop() async { stopped = true }
    func cancel() { stopped = true } // Deliberately does not release start's external operation.
}
