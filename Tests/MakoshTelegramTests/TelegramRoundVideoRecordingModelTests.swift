#if DEBUG
import AVFoundation
import XCTest
@testable import MakoshTelegram

@MainActor private final class ModelRoundRecordingDevice: TelegramRoundVideoCapture {
    var isRecording = false
    var duration: Double { 1 }; var level: Float { 0.5 }
    var previewSession: AVCaptureSession? { nil }
    var startup: CheckedContinuation<Void, Error>?
    var waitForStartup = false
    var cancelled = false
    func start() async throws {
        if waitForStartup { try await withCheckedThrowingContinuation { startup = $0 } }
        if !cancelled { isRecording = true }
    }
    func stop() async throws -> Data { isRecording = false; return Data([1]) }
    func cancel() { cancelled = true; isRecording = false }
}

@MainActor final class TelegramRoundVideoRecordingModelTests: XCTestCase {
    private func fixture() -> (TelegramModel, ModelRoundRecordingDevice) {
        let model = TelegramModel.syntheticPreview(), capture = ModelRoundRecordingDevice()
        model.selectedChatID = 10001
        model.voiceRecording.toggleKind()
        model.voiceRecording.makeRoundVideoCapture = { capture }
        return (model, capture)
    }
    // Catches an unbound model round ACL/permission path and any accidental use
    // of the voice gate for the selected round action.
    func testModelBindsIndependentRoundEligibilityAndAuthorization() async {
        let (model, capture) = fixture()
        model.voiceRecording.authorize = { false }
        model.voiceRecording.eligibility = { _ in .restricted }
        model.beginVoiceRecording()
        await wait { model.voiceRecording.phase != .authorizing }
        XCTAssertEqual(model.voiceRecording.phase, .recording)
        XCTAssertTrue(capture.isRecording)
        model.cancelVoiceRecording()
    }
    func testChatSwitchCancelsWarmingCameraAndCannotReviveOnReturn() async {
        let (model, capture) = fixture()
        capture.waitForStartup = true
        model.beginVoiceRecording()
        await wait { capture.startup != nil || model.voiceRecording.phase == .failed }
        XCTAssertNotNil(capture.startup)
        model.selectedChatID = 10002; model.selectedChatID = 10001
        capture.startup?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.voiceRecording.phase, .idle)
        XCTAssertTrue(capture.cancelled); XCTAssertFalse(capture.isRecording)
        XCTAssertEqual(model.upload.phase, .idle)
    }
    func testRoundCannotReplaceTypedTextOrStartFromAnOldHoldContext() async {
        let (model, capture) = fixture(), old = model.voiceInputContextID
        model.draft = "Keep this draft"
        model.beginVoiceRecording()
        XCTAssertEqual(model.draft, "Keep this draft"); XCTAssertFalse(capture.isRecording)
        model.draft = ""; model.selectedChatID = 10002; model.selectedChatID = 10001
        model.beginVoiceRecording(contextID: old)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.voiceRecording.phase, .idle); XCTAssertFalse(capture.isRecording)
    }
    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic round model did not settle")
    }
}
#endif
