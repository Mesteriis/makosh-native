import XCTest
@testable import MakoshTelegram

// Only device/permission and the external destination are controlled. Tests
// exercise the real state machine; no microphone permission is requested.
@MainActor private final class RecordingDevice: TelegramVoiceCapture {
    var duration: Double = 1
    var level: Float = 0.5
    var isRecording = false
    var samples = [Int16](repeating: 1000, count: 48_000)
    var stopGate: CheckedContinuation<[Int16], any Error>?
    var heldStop = false
    func start() throws { isRecording = true }
    func stop() async throws -> [Int16] {
        isRecording = false
        if heldStop { return try await withCheckedThrowingContinuation { stopGate = $0 } }
        return samples
    }
    func cancel() { isRecording = false }
}

@MainActor final class TelegramVoiceRecordingControllerTests: XCTestCase {
    func testOneTimeSelectionNeedsLockAndFreezesBeforeAsynchronousStop() async {
        let capture = RecordingDevice(), value = controller(capture)
        capture.heldStop = true
        value.oneTimeEligibility = { _ in true }
        var delivered: Bool?
        value.handoff = { _,_,_,_,once in delivered = once; return true }
        value.setOneTime(true); XCTAssertFalse(value.isOneTime)
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        XCTAssertTrue(value.canUseOneTime)
        value.setOneTime(true); XCTAssertFalse(value.isOneTime)
        value.move(upward: 101); value.setOneTime(true); XCTAssertTrue(value.isOneTime)
        value.setOneTime(false); XCTAssertFalse(value.isOneTime)
        value.setOneTime(true); value.send(); await wait { capture.stopGate != nil }
        value.setOneTime(false); XCTAssertTrue(value.isOneTime)
        capture.stopGate?.resume(returning: capture.samples)
        await wait { value.phase == .idle }
        XCTAssertEqual(delivered, true)
        XCTAssertFalse(value.isOneTime); XCTAssertFalse(value.canUseOneTime)
    }
    func testIneligibleLockedRecordingNeverSelectsOneTime() async {
        let value = controller(RecordingDevice())
        value.oneTimeEligibility = { _ in false }
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        value.move(upward: 101); value.setOneTime(true)
        XCTAssertFalse(value.canUseOneTime); XCTAssertFalse(value.isOneTime)
        value.cancel()
    }
    func testCancelledOneTimeCapabilityCannotStartOrChangeReplacementCapture() async {
        let capture = RecordingDevice(), value = controller(capture)
        var pending: CheckedContinuation<Bool, Never>?
        value.oneTimeEligibility = { _ in await withCheckedContinuation { pending = $0 } }
        value.begin(target: target, contextID: context); await wait { pending != nil }
        XCTAssertFalse(capture.isRecording)
        value.cancel(); value.oneTimeEligibility = { _ in false }
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        pending?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(value.canUseOneTime); XCTAssertFalse(value.isOneTime)
        XCTAssertTrue(capture.isRecording)
        value.cancel()
    }
    func testOrdinaryPermissionIsFreshAfterWaitingForOneTimeCapability() async {
        let capture = RecordingDevice(), value = controller(capture)
        var permission: TelegramVoiceEligibility = .allowed
        var pending: CheckedContinuation<Bool, Never>?
        value.eligibility = { _ in permission }
        value.oneTimeEligibility = { _ in await withCheckedContinuation { pending = $0 } }
        value.begin(target: target, contextID: context); await wait { pending != nil }
        permission = .voicePrivacy; pending?.resume(returning: false)
        await wait { value.phase != .authorizing }
        XCTAssertEqual(value.phase, .failed); XCTAssertFalse(capture.isRecording)
        XCTAssertEqual(value.error, "Собеседник запретил отправку голосовых сообщений.")
        value.cancel()
    }
    private let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
    private let context = UUID()
    private func controller(_ capture: RecordingDevice) -> TelegramVoiceRecordingController {
        let value = TelegramVoiceRecordingController()
        value.authorize = { true }; value.makeCapture = { capture }
        value.eligibility = { _ in .allowed }; value.isCurrent = { _,_ in true }
        return value
    }
    private func wait(_ test: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if test() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Recording state did not settle", file: file, line: line)
    }

    // Catches a release submitting the wrong target, stale context or duplicate
    // audio, or bypassing the handoff's async durable preparation.
    func testReleaseInsideHandsOffFrozenPCMOnce() async {
        let capture = RecordingDevice(), value = controller(capture)
        var deliveries: [(TelegramUploadTarget, UUID, Bool, Int)] = []
        var handoffGate: CheckedContinuation<Bool, Never>?
        value.handoff = { samples, target, context, send, _ in
            deliveries.append((target, context, send, samples.count))
            return await withCheckedContinuation { handoffGate = $0 }
        }
        value.begin(target: target, contextID: context)
        await wait { value.phase == .recording }
        XCTAssertEqual(value.duration, 1); XCTAssertEqual(value.level, 0.5)
        value.release(inside: true); value.release(inside: true); value.send()
        await wait { handoffGate != nil }
        XCTAssertEqual(value.phase, .finishing); XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.0, target); XCTAssertEqual(deliveries.first?.1, context)
        XCTAssertEqual(deliveries.first?.2, true); XCTAssertEqual(deliveries.first?.3, 48_000)
        handoffGate?.resume(returning: true)
        await wait { value.phase == .idle }
        XCTAssertFalse(capture.isRecording); XCTAssertNil(value.error)
    }

    // Permission can return after a release, navigation or replacement request.
    // It must never resurrect cancelled hardware or replace the current session.
    func testReleaseWhileAuthorizingCannotStartAfterLatePermission() async {
        let capture = RecordingDevice(), value = controller(capture)
        var permission: CheckedContinuation<Bool, Never>?
        value.authorize = { await withCheckedContinuation { permission = $0 } }
        value.begin(target: target, contextID: context)
        await wait { permission != nil }
        XCTAssertEqual(value.phase, .authorizing)
        value.release(inside: true)
        permission?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(value.phase, .idle); XCTAssertFalse(capture.isRecording)
    }
    // A keyboard/accessibility start or upward drag during the permission wait
    // must lock the eventual session, without starting hardware prematurely.
    func testLockIntentDuringAuthorizationAppliesOnlyAfterCaptureStarts() async {
        let capture = RecordingDevice(), value = controller(capture)
        var permission: CheckedContinuation<Bool, Never>?
        value.authorize = { await withCheckedContinuation { permission = $0 } }
        value.begin(target: target, contextID: context)
        await wait { permission != nil }
        value.move(upward: 101)
        XCTAssertEqual(value.phase, .authorizing); XCTAssertFalse(capture.isRecording)
        value.release(inside: false)
        XCTAssertEqual(value.phase, .authorizing)
        permission?.resume(returning: true)
        await wait { value.phase == .locked }
        XCTAssertTrue(capture.isRecording)
        value.release(inside: false); XCTAssertEqual(value.phase, .locked)
        value.cancel()
    }

    // Catches ignoring inside/outside release or treating the exact100pt
    // threshold as locked. The reference requires a movement strictly above100.
    func testOutsideReleaseCancelsAndLockNeedsExplicitSend() async {
        let capture = RecordingDevice(), value = controller(capture)
        var delivered = 0
        value.handoff = { _,_,_,_,_ in delivered += 1; return true }
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        value.move(upward: 100); XCTAssertEqual(value.phase, .recording)
        value.release(inside: false); XCTAssertEqual(value.phase, .idle)
        XCTAssertEqual(delivered, 0); XCTAssertFalse(capture.isRecording)
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        value.move(upward: 101); XCTAssertEqual(value.phase, .locked)
        value.release(inside: false); XCTAssertEqual(value.phase, .locked)
        value.send(); await wait { delivered == 1 && value.phase == .idle }
    }

    // Catches an old confirmation cancelling a new session; locked recordings
    // require confirmation, lifecycle cancellation always cleans immediately.
    func testLockedCancelConfirmationBelongsToItsSession() async throws {
        let capture = RecordingDevice(), value = controller(capture)
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        value.move(upward: 101); value.requestCancel()
        let old = try XCTUnwrap(value.cancelConfirmationID)
        XCTAssertEqual(value.phase, .locked); XCTAssertTrue(capture.isRecording)
        value.cancel(); XCTAssertFalse(capture.isRecording)
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        value.move(upward: 101); value.confirmCancel(id: old)
        XCTAssertEqual(value.phase, .locked)
        value.requestCancel(); value.confirmCancel(id: try XCTUnwrap(value.cancelConfirmationID))
        XCTAssertEqual(value.phase, .idle); XCTAssertFalse(capture.isRecording)
    }

    // Catches opening hardware before peer eligibility, or using a permission
    // grant after peer rights/context changed while the system prompt was open.
    func testRestrictionsAndContextAreCheckedBeforeAndAfterAuthorization() async {
        let capture = RecordingDevice(), value = controller(capture)
        value.eligibility = { _ in .voicePrivacy }
        value.begin(target: target, contextID: context); await wait { value.phase == .failed }
        XCTAssertFalse(capture.isRecording); XCTAssertNotNil(value.error)
        var current = true
        value.eligibility = { _ in .allowed }; value.isCurrent = { _,_ in current }
        value.authorize = { current = false; return true }
        value.begin(target: target, contextID: context); await wait { value.phase == .idle }
        XCTAssertFalse(capture.isRecording)
        current = true
        value.authorize = { value.eligibility = { _ in .restricted }; return true }
        value.begin(target: target, contextID: context); await wait { value.phase == .failed }
        XCTAssertFalse(capture.isRecording)
    }

    // Catches sending subminimum audio, and an async stop completing after
    // navigation. No abandoned session may reach durable handoff.
    func testShortCaptureAndCancelledStopNeverHandOff() async {
        let capture = RecordingDevice(), value = controller(capture)
        var delivered = 0
        value.handoff = { _,_,_,_,_ in delivered += 1; return true }
        capture.samples = [Int16](repeating: 1, count: 24_959)
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        value.release(inside: true); await wait { value.phase == .idle }
        XCTAssertEqual(delivered, 0)
        capture.heldStop = true; capture.samples = [Int16](repeating: 1, count: 48_000)
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        value.send(); await wait { capture.stopGate != nil }
        value.cancel(); capture.stopGate?.resume(returning: capture.samples)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(delivered, 0); XCTAssertEqual(value.phase, .idle)
    }

    // A finite recording cap must retain audio for explicit send rather than
    // silently transmitting when native recording stops on its own.
    func testNativeAutoStopPreparesWithoutAutomaticSend() async {
        let capture = RecordingDevice(), value = controller(capture)
        var sendIntent: Bool?
        value.handoff = { _,_,_,send,_ in sendIntent = send; return true }
        value.begin(target: target, contextID: context); await wait { value.phase == .recording }
        capture.isRecording = false
        await wait { sendIntent != nil && value.phase == .idle }
        XCTAssertEqual(sendIntent, false)
    }
}
