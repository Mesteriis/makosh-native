#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramSyntheticRoundVideoCaptureTests: XCTestCase {
    // The UI's explicit synthetic mode must use the actual writer and encoded
    // admission, with generated pixels/PCM and no device or permission calls.
    func testSyntheticCaptureProducesAdmissibleRoundBytesWithoutADevice() async throws {
        let capture = try TelegramSyntheticRoundVideoCapture()
        do { try await capture.start() }
        catch { return XCTFail("Synthetic round capture did not start: \(error)") }
        XCTAssertTrue(capture.isRecording); XCTAssertNil(capture.previewSession)
        try await Task.sleep(for: .milliseconds(800))
        let bytes = try await capture.stop()
        XCTAssertFalse(capture.isRecording)
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.pixelWidth, 300); XCTAssertEqual(file.pixelHeight, 300)
        XCTAssertNotNil(file.metadata?.roundVideo)
        XCTAssertGreaterThanOrEqual(file.video?.duration ?? 0, 0.5)
    }
}
#endif
