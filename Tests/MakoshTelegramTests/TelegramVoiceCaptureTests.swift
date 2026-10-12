import AVFoundation
import Foundation
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramVoiceCaptureTests: XCTestCase {
    // The permission boundary treats every non-authorized status as a refusal, never as a request.
    func testAuthorizationBoundaryRequiresAnExplicitExistingGrant() throws {
        for status: AVAuthorizationStatus in [.notDetermined, .restricted, .denied] {
            XCTAssertThrowsError(try TelegramVoiceCapturePermission.requireAuthorized(status)) { error in
                XCTAssertEqual(error as? TelegramVoiceCaptureError, .permissionDenied)
            }
        }
        XCTAssertNoThrow(try TelegramVoiceCapturePermission.requireAuthorized(.authorized))
    }

    // Constructing or cancelling a recorder must neither start hardware nor manufacture a recording.
    func testIdleAndCancelledCaptureCannotProducePCM() async throws {
        let capture = try TelegramMicrophoneVoiceCapture()
        XCTAssertFalse(capture.isRecording)
        XCTAssertEqual(capture.duration, 0)
        XCTAssertEqual(capture.level, 0)
        do { _ = try await capture.stop(); XCTFail("Idle capture produced PCM") }
        catch { XCTAssertEqual(error as? TelegramVoiceCaptureError, .invalidState) }
        capture.cancel(); capture.cancel()
        XCTAssertFalse(capture.isRecording)
        do { _ = try await capture.stop(); XCTFail("Cancelled capture produced PCM") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    // A denied/not-determined system capability must refuse before any recording or permission request.
    func testStartRefusesWithoutPriorMicrophoneAuthorization() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .authorized else {
            throw XCTSkip("No hardware is used when this test process already has microphone authorization")
        }
        let capture = try TelegramMicrophoneVoiceCapture()
        defer { capture.cancel() }
        XCTAssertThrowsError(try capture.start()) { error in
            XCTAssertEqual(error as? TelegramVoiceCaptureError, .permissionDenied)
        }
        XCTAssertFalse(capture.isRecording)
    }
}
