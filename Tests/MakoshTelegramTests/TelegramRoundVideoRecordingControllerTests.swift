import XCTest
import AVFoundation
@testable import MakoshTelegram

// Control only device readiness and external handoff. The actual controller is
// exercised without adding inputs, running a session or requesting permission.
@MainActor private final class RoundRecordingDevice: TelegramRoundVideoCapture {
    var duration: Double = 1
    var level: Float = 0.25
    var isRecording = false
    let previewSession: AVCaptureSession? = AVCaptureSession()
    var bytes = Data([0x11, 0x22, 0x33])
    var heldStart = false
    var heldStop = false
    var failStart = false
    var failStop = false
    var starts = 0
    var stops = 0
    var cancellations = 0
    var startGate: CheckedContinuation<Void, any Error>?
    var stopGate: CheckedContinuation<Data, any Error>?
    func start() async throws {
        starts += 1
        if heldStart { try await withCheckedThrowingContinuation { startGate = $0 } }
        if failStart { throw CancellationError() }
        // Deliberately ignores cancellation until the old start returns; the
        // controller must cancel this instance without touching a replacement.
        isRecording = true
    }
    func stop() async throws -> Data {
        stops += 1; isRecording = false
        if heldStop { return try await withCheckedThrowingContinuation { stopGate = $0 } }
        if failStop { throw CancellationError() }
        return bytes
    }
    func cancel() { cancellations += 1; isRecording = false }
}

@MainActor final class TelegramRoundVideoRecordingControllerTests: XCTestCase {
    private let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic round")
    private let context = UUID()
    private func controller(_ capture: RoundRecordingDevice) -> TelegramVoiceRecordingController {
        let value = TelegramVoiceRecordingController()
        value.authorize = { true }; value.eligibility = { _ in .allowed }
        value.authorizeRoundVideo = { true }; value.makeRoundVideoCapture = { capture }
        value.roundVideoEligibility = { _ in .allowed }
        value.roundVideoOneTimeEligibility = { _ in false }
        value.isCurrent = { _, _ in true }
        value.toggleKind()
        return value
    }
    private func wait(_ test: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if test() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Round recording state did not settle", file: file, line: line)
    }

    // A short click can change the next recording, never a live session.
    func testKindDefaultsToVoiceAndChangesOnlyWhenIdleOrFailed() async {
        let capture = RoundRecordingDevice(), value = TelegramVoiceRecordingController()
        XCTAssertEqual(value.selectedKind, .voice); XCTAssertNil(value.previewSession)
        value.toggleKind(); XCTAssertEqual(value.selectedKind, .roundVideo)
        value.roundVideoEligibility = { _ in .restricted }; value.isCurrent = { _, _ in true }
        value.begin(target: target, contextID: context)
        await wait { value.phase == .failed }
        value.toggleKind(); XCTAssertEqual(value.selectedKind, .voice)
        value.toggleKind(); XCTAssertEqual(value.selectedKind, .roundVideo)
        value.roundVideoEligibility = { _ in .allowed }; value.authorizeRoundVideo = { true }
        value.makeRoundVideoCapture = { capture }
        value.begin(target: target, contextID: context)
        await wait { value.phase == .recording || value.phase == .failed }
        XCTAssertEqual(value.phase, .recording)
        value.toggleKind(); XCTAssertEqual(value.selectedKind, .roundVideo)
        value.move(upward: 101); value.toggleKind(); XCTAssertEqual(value.selectedKind, .roundVideo)
        value.cancel(); XCTAssertEqual(value.selectedKind, .roundVideo)
        value.toggleKind(); XCTAssertEqual(value.selectedKind, .voice)
    }

    // Wrong dependency selection, duplicate stop, lost once/target/context or
    // mutable mode during an async stop would break the real handoff contract.
    func testRoundHandoffFreezesKindOnceTargetAndContextBeforeStop() async {
        let capture = RoundRecordingDevice(), value = controller(capture)
        capture.heldStop = true
        var voiceCalls = 0, roundChecks = 0, permissions = 0, capabilities = 0
        value.eligibility = { _ in voiceCalls += 1; return .restricted }
        value.authorize = { voiceCalls += 1; return false }
        value.oneTimeEligibility = { _ in voiceCalls += 1; return false }
        value.handoff = { _, _, _, _, _ in voiceCalls += 1; return false }
        value.roundVideoEligibility = { _ in roundChecks += 1; return .allowed }
        value.authorizeRoundVideo = { permissions += 1; return true }
        value.roundVideoOneTimeEligibility = { _ in capabilities += 1; return true }
        var deliveries: [(Data, TelegramUploadTarget, UUID, Bool, Bool)] = []
        value.roundVideoHandoff = { bytes, target, context, send, once in
            deliveries.append((bytes, target, context, send, once)); return true
        }
        value.setOneTime(true); XCTAssertFalse(value.isOneTime)
        value.begin(target: target, contextID: context)
        await wait { value.phase == .recording || value.phase == .failed }
        XCTAssertEqual(value.phase, .recording); XCTAssertEqual(value.duration, 1); XCTAssertEqual(value.level, 0.25)
        XCTAssertTrue(value.previewSession === capture.previewSession)
        XCTAssertEqual(roundChecks, 2); XCTAssertEqual(permissions, 1); XCTAssertEqual(capabilities, 1)
        value.setOneTime(true); XCTAssertFalse(value.isOneTime)
        value.move(upward: 100); XCTAssertEqual(value.phase, .recording)
        value.move(upward: 101); value.setOneTime(true); XCTAssertTrue(value.isOneTime)
        value.send()
        await wait { capture.stopGate != nil || value.phase == .failed }
        value.toggleKind(); value.setOneTime(false); value.send(); value.release(inside: true)
        XCTAssertEqual(value.phase, .finishing); XCTAssertEqual(value.selectedKind, .roundVideo); XCTAssertTrue(value.isOneTime)
        capture.stopGate?.resume(returning: capture.bytes); capture.stopGate = nil
        await wait { value.phase == .idle || value.phase == .failed }
        XCTAssertEqual(voiceCalls, 0); XCTAssertEqual(capture.stops, 1); XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.0, Data([0x11, 0x22, 0x33]))
        XCTAssertEqual(deliveries.first?.1, target); XCTAssertEqual(deliveries.first?.2, context)
        XCTAssertEqual(deliveries.first?.3, true); XCTAssertEqual(deliveries.first?.4, true)
        XCTAssertFalse(value.isOneTime); XCTAssertFalse(value.canUseOneTime); XCTAssertNil(value.previewSession)
    }

    // Starting hardware is asynchronous: metering must not finish an unready
    // session merely because isRecording is still false.
    func testWarmupRemainsAuthorizingAndReleaseCancelsAttachedCapture() async {
        let capture = RoundRecordingDevice(), value = controller(capture)
        capture.heldStart = true; capture.duration = 60
        var handoffs = 0
        value.roundVideoHandoff = { _, _, _, _, _ in handoffs += 1; return true }
        value.begin(target: target, contextID: context)
        await wait { capture.startGate != nil || value.phase == .failed }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(value.phase, .authorizing); XCTAssertEqual(capture.stops, 0); XCTAssertEqual(handoffs, 0)
        XCTAssertTrue(value.previewSession === capture.previewSession)
        value.toggleKind(); XCTAssertEqual(value.selectedKind, .roundVideo)
        value.release(inside: true)
        XCTAssertEqual(value.phase, .idle); XCTAssertGreaterThanOrEqual(capture.cancellations, 1)
        capture.startGate?.resume(); capture.startGate = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(value.phase, .idle); XCTAssertFalse(capture.isRecording); XCTAssertEqual(handoffs, 0)
    }

    func testUpwardLockDuringWarmupSurvivesReleaseAndRequiresConfirmationToCancel() async throws {
        let capture = RoundRecordingDevice(), value = controller(capture)
        capture.heldStart = true
        value.begin(target: target, contextID: context)
        await wait { capture.startGate != nil || value.phase == .failed }
        value.move(upward: 101); value.release(inside: false)
        XCTAssertEqual(value.phase, .authorizing)
        capture.startGate?.resume(); capture.startGate = nil
        await wait { value.phase == .locked || value.phase == .failed }
        XCTAssertEqual(value.phase, .locked); XCTAssertTrue(capture.isRecording)
        value.requestCancel(); XCTAssertEqual(value.phase, .locked)
        if let id = value.cancelConfirmationID { value.confirmCancel(id: id) }
        else { XCTFail("Locked round recording has no cancellation confirmation") }
        XCTAssertEqual(value.phase, .idle); XCTAssertFalse(capture.isRecording); XCTAssertNil(value.previewSession)
    }

    // A late successful or failed start belongs to the old capture object.
    func testCancelledWarmupCannotReviveOrFailReplacementRecording() async {
        for fails in [false, true] {
            let old = RoundRecordingDevice(), replacement = RoundRecordingDevice(), value = controller(old)
            old.heldStart = true; old.failStart = fails
            value.begin(target: target, contextID: context)
            await wait { old.startGate != nil || value.phase == .failed }
            value.cancel(); value.makeRoundVideoCapture = { replacement }
            value.begin(target: target, contextID: context)
            await wait { value.phase == .recording || value.phase == .failed }
            old.startGate?.resume(); old.startGate = nil
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(value.phase, .recording); XCTAssertTrue(replacement.isRecording)
            XCTAssertFalse(old.isRecording); XCTAssertTrue(value.previewSession === replacement.previewSession)
            XCTAssertNil(value.error); value.cancel()
        }
    }

    func testCancelledStopCannotHandOffOrResetReplacementRecording() async {
        let old = RoundRecordingDevice(), replacement = RoundRecordingDevice(), value = controller(old)
        old.heldStop = true
        var handoffs = 0
        value.roundVideoHandoff = { _, _, _, _, _ in handoffs += 1; return true }
        value.begin(target: target, contextID: context)
        await wait { value.phase == .recording || value.phase == .failed }
        value.send(); await wait { old.stopGate != nil || value.phase == .failed }
        value.cancel(); value.makeRoundVideoCapture = { replacement }
        value.begin(target: target, contextID: context)
        await wait { value.phase == .recording || value.phase == .failed }
        old.stopGate?.resume(returning: old.bytes); old.stopGate = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(handoffs, 0); XCTAssertEqual(value.phase, .recording)
        XCTAssertTrue(replacement.isRecording); XCTAssertTrue(value.previewSession === replacement.previewSession)
        value.cancel()
    }

    func testLateHandoffResultCannotCancelOrFailReplacementRecording() async {
        for admitted in [true, false] {
            let old = RoundRecordingDevice(), replacement = RoundRecordingDevice(), value = controller(old)
            var gate: CheckedContinuation<Bool, Never>?
            value.roundVideoHandoff = { _, _, _, _, _ in await withCheckedContinuation { gate = $0 } }
            value.begin(target: target, contextID: context)
            await wait { value.phase == .recording || value.phase == .failed }
            value.send(); await wait { gate != nil || value.phase == .failed }
            value.cancel(); value.makeRoundVideoCapture = { replacement }
            value.begin(target: target, contextID: context)
            await wait { value.phase == .recording || value.phase == .failed }
            gate?.resume(returning: admitted); gate = nil
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(value.phase, .recording); XCTAssertTrue(replacement.isRecording); XCTAssertNil(value.error)
            value.cancel()
        }
    }

    func testRoundRestrictionsAndDeniedPermissionNeverConstructCapture() async {
        let capture = RoundRecordingDevice(), value = controller(capture)
        var permissions = 0, constructions = 0
        value.authorizeRoundVideo = { permissions += 1; return false }
        value.makeRoundVideoCapture = { constructions += 1; return capture }
        value.roundVideoEligibility = { _ in .voicePrivacy }
        value.begin(target: target, contextID: context); await wait { value.phase == .failed }
        XCTAssertEqual(value.error, TelegramVoiceEligibility.voicePrivacy.explanation(for: .roundVideo))
        XCTAssertEqual(permissions, 0); XCTAssertEqual(constructions, 0)
        value.roundVideoEligibility = { _ in .allowed }
        value.begin(target: target, contextID: context); await wait { value.phase == .failed }
        XCTAssertEqual(permissions, 1); XCTAssertEqual(constructions, 0)
        XCTAssertTrue(value.error?.contains("камер") == true); XCTAssertTrue(value.error?.contains("микрофон") == true)
    }

    func testFreshRoundPermissionAfterCapabilityWaitPreventsStart() async {
        let capture = RoundRecordingDevice(), value = controller(capture)
        var permission: TelegramVoiceEligibility = .allowed
        var gate: CheckedContinuation<Bool, Never>?
        value.roundVideoEligibility = { _ in permission }
        value.roundVideoOneTimeEligibility = { _ in await withCheckedContinuation { gate = $0 } }
        value.begin(target: target, contextID: context)
        await wait { gate != nil || value.phase == .failed }
        permission = .restricted; gate?.resume(returning: true); gate = nil
        await wait { value.phase == .failed }
        XCTAssertEqual(capture.starts, 0); XCTAssertFalse(capture.isRecording)
        XCTAssertEqual(value.error, TelegramVoiceEligibility.restricted.explanation(for: .roundVideo))
        XCTAssertFalse(value.canUseOneTime); XCTAssertFalse(value.isOneTime)
    }

    func testContextLossDuringWarmupCleansCaptureWithoutHandoff() async {
        let capture = RoundRecordingDevice(), value = controller(capture)
        capture.heldStart = true
        var current = true, handoffs = 0
        value.isCurrent = { _, _ in current }
        value.roundVideoHandoff = { _, _, _, _, _ in handoffs += 1; return true }
        value.begin(target: target, contextID: context)
        await wait { capture.startGate != nil || value.phase == .failed }
        current = false; capture.startGate?.resume(); capture.startGate = nil
        await wait { value.phase == .idle || value.phase == .failed }
        XCTAssertEqual(value.phase, .idle); XCTAssertFalse(capture.isRecording); XCTAssertEqual(handoffs, 0)
        XCTAssertGreaterThanOrEqual(capture.cancellations, 1); XCTAssertNil(value.previewSession)
    }

    // The reference's 60s cap and native auto-stop only prepare; neither may
    // infer permission to send. Encoded min/max validity belongs downstream.
    func testRoundCapAndNativeAutoStopPrepareWithoutAutomaticSend() async {
        for capped in [true, false] {
            let capture = RoundRecordingDevice(), value = controller(capture)
            var delivered: (Data, Bool, Bool)?
            value.roundVideoOneTimeEligibility = { _ in true }
            value.roundVideoHandoff = { bytes, _, _, send, once in delivered = (bytes, send, once); return true }
            value.begin(target: target, contextID: context)
            await wait { value.phase == .recording || value.phase == .failed }
            value.move(upward: 101); value.setOneTime(true)
            if capped { capture.duration = 60 } else { capture.isRecording = false }
            await wait { delivered != nil || value.phase == .failed }
            XCTAssertEqual(delivered?.0, capture.bytes); XCTAssertEqual(delivered?.1, false); XCTAssertEqual(delivered?.2, true)
            XCTAssertEqual(capture.stops, 1); value.cancel()
        }
    }

    func testRoundStartStopAndHandoffFailuresUseVideoErrorAndCleanPreview() async {
        for failure in 0..<3 {
            let capture = RoundRecordingDevice(), value = controller(capture)
            capture.failStart = failure == 0; capture.failStop = failure == 1
            value.roundVideoHandoff = { _, _, _, _, _ in false }
            value.begin(target: target, contextID: context)
            await wait { value.phase == .recording || value.phase == .failed }
            if failure != 0 { value.send() }
            await wait { value.phase == .failed }
            XCTAssertFalse(capture.isRecording); XCTAssertNil(value.previewSession); XCTAssertEqual(value.duration, 0)
            XCTAssertFalse(value.error?.contains("голос") == true)
            XCTAssertTrue(value.error?.contains(failure == 0 ? "камер" : "видео") == true)
        }
    }
}
