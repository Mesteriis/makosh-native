import AVFoundation
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramRecordingPermissionRequestTests: XCTestCase {
    // A device provider must never prompt. This model-owned gate requests only
    // missing permissions, and a cancelled camera prompt cannot prompt for audio.
    func testRoundRequestsCameraThenAudioAndVoiceNeedsOnlyAudio() async {
        let gate = TelegramRecordingPermissionRequest()
        gate.status = { _ in .notDetermined }
        var requested: [AVMediaType] = []
        gate.request = { requested.append($0); return true }
        let round = await gate.authorize(kind: .roundVideo, isCurrent: { true })
        XCTAssertTrue(round); XCTAssertEqual(requested, [.video, .audio])
        requested = []
        let voice = await gate.authorize(kind: .voice, isCurrent: { true })
        XCTAssertTrue(voice); XCTAssertEqual(requested, [.audio])
    }
    func testAuthorizedDevicesNeedNoPromptAndDeniedCameraStopsBeforeAudio() async {
        let gate = TelegramRecordingPermissionRequest()
        var requested: [AVMediaType] = []
        gate.request = { requested.append($0); return true }
        gate.status = { _ in .authorized }
        let allowed = await gate.authorize(kind: .roundVideo, isCurrent: { true })
        XCTAssertTrue(allowed); XCTAssertTrue(requested.isEmpty)
        for status in [AVAuthorizationStatus.denied, .restricted] {
            gate.status = { $0 == .video ? status : .notDetermined }
            let denied = await gate.authorize(kind: .roundVideo, isCurrent: { true })
            XCTAssertFalse(denied); XCTAssertTrue(requested.isEmpty)
        }
    }
    func testContextLossDuringCameraPromptNeverRequestsMicrophone() async {
        let gate = TelegramRecordingPermissionRequest()
        gate.status = { _ in .notDetermined }
        var current = true, requested: [AVMediaType] = []
        var prompt: CheckedContinuation<Bool, Never>?
        gate.request = { type in
            requested.append(type)
            return await withCheckedContinuation { prompt = $0 }
        }
        let operation = Task { await gate.authorize(kind: .roundVideo, isCurrent: { current }) }
        for _ in 0..<100 where prompt == nil { await Task.yield() }
        XCTAssertNotNil(prompt)
        current = false; prompt?.resume(returning: true)
        let allowed = await operation.value
        XCTAssertFalse(allowed); XCTAssertEqual(requested, [.video])
    }
    func testDeniedPromptAndInitiallyStaleContextFailClosed() async {
        let gate = TelegramRecordingPermissionRequest()
        gate.status = { _ in .notDetermined }
        var requested: [AVMediaType] = []
        gate.request = { requested.append($0); return false }
        let stale = await gate.authorize(kind: .roundVideo, isCurrent: { false })
        XCTAssertFalse(stale); XCTAssertTrue(requested.isEmpty)
        let denied = await gate.authorize(kind: .roundVideo, isCurrent: { true })
        XCTAssertFalse(denied); XCTAssertEqual(requested, [.video])
    }
}
