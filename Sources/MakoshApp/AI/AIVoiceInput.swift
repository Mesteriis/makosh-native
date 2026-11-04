import AVFoundation
import Foundation

/// Dictation recorder for the AI composer. The recording is a temporary
/// m4a file that the caller transcribes and deletes; nothing is archived.
@MainActor final class AIVoiceInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var denied = false
    private var recorder: AVAudioRecorder?

    func start() async {
        guard !isRecording else { return }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
        default: granted = false
        }
        denied = !granted
        guard granted else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-ai-dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else { return }
        self.recorder = recorder
        isRecording = true
    }

    /// Returns the recorded file, or nil when nothing was recorded.
    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        self.recorder = nil
        isRecording = false
        return recorder.url
    }
}
