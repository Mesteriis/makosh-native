#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor private final class ModelRecordingDevice: TelegramVoiceCapture {
    var duration: Double { 1 }; var level: Float { 0.5 }
    var isRecording = false
    func start() throws { isRecording = true }
    func stop() async throws -> [Int16] { isRecording = false; return [Int16](repeating: 1, count: 48_000) }
    func cancel() { isRecording = false }
}
@MainActor final class TelegramVoiceRecordingModelTests: XCTestCase {
    private func fixture() -> (TelegramModel, ModelRecordingDevice) {
        let model = TelegramModel.syntheticPreview(), device = ModelRecordingDevice()
        model.selectedChatID = 10001
        model.voiceRecording.authorize = { true }
        model.voiceRecording.makeCapture = { device }
        model.voiceRecording.eligibility = { _ in .allowed }
        return (model, device)
    }
    private func recording(_ model: TelegramModel) async {
        for _ in 0..<200 {
            if model.voiceRecording.phase == .recording { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic recorder did not start")
    }
    // Catches replacing typed text with audio or offering capture without a
    // selected, ready cloud conversation and an empty ordinary composer.
    func testOnlyEmptyOrdinaryComposerCanBegin() {
        let plain = TelegramModel(); XCTAssertFalse(plain.canStartVoiceRecording)
        let (model, device) = fixture(); XCTAssertTrue(model.canStartVoiceRecording)
        model.draft = "Preserve text"; XCTAssertFalse(model.canStartVoiceRecording)
        model.beginVoiceRecording(); XCTAssertFalse(device.isRecording)
        XCTAssertEqual(model.draft, "Preserve text")
        model.draft = ""; XCTAssertTrue(model.canStartVoiceRecording)
        model.selectedChatID = nil; XCTAssertFalse(model.canStartVoiceRecording)
    }
    // Catches changing the reply/chat or leaving the common Telegram surface
    // while capture continues invisibly; the next chat must keep its own draft.
    func testChatSwitchAndSurfaceCancellationStopCapture() async {
        let (model, device) = fixture()
        model.beginVoiceRecording(); await recording(model)
        XCTAssertTrue(device.isRecording); XCTAssertFalse(model.canStartVoiceRecording)
        let input = try! TelegramComposerInput(formattedText: .init(text: "Must not overwrite capture"))
        XCTAssertFalse(model.updateComposerInput(input, contextID: model.messageActionContextID, chatID: 10001))
        model.selectedChatID = 10002
        XCTAssertEqual(model.voiceRecording.phase, .idle); XCTAssertFalse(device.isRecording)
        XCTAssertEqual(model.draft, "")
        model.beginVoiceRecording(); await recording(model)
        model.cancelVoiceRecording(); XCTAssertFalse(device.isRecording)
        XCTAssertEqual(model.voiceRecording.phase, .idle)
    }
    // A delayed native long-press must not start in a replacement chat, even
    // after returning to the original chat during the300ms hold threshold.
    func testDelayedHoldFromOldSurfaceCannotBeginANewCapture() async {
        let (model, device) = fixture(), old = model.voiceInputContextID
        model.selectedChatID = 10002; model.selectedChatID = 10001
        model.beginVoiceRecording(contextID: old)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.voiceRecording.phase, .idle); XCTAssertFalse(device.isRecording)
    }
}
#endif
