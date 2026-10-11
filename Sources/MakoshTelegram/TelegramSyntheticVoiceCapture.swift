#if DEBUG
import Foundation

/// Explicit syntheticPreview only; never instantiates a device or permission API.
@MainActor final class TelegramSyntheticVoiceCapture: TelegramVoiceCapture {
    private var started: TimeInterval?
    private var stoppedDuration: Double = 0
    var duration: Double { min(600, started.map { ProcessInfo.processInfo.systemUptime - $0 } ?? stoppedDuration) }
    var level: Float { isRecording ? 0.4 : 0 }
    var isRecording: Bool { started != nil && duration < 600 }
    func start() throws { stoppedDuration = 0; started = ProcessInfo.processInfo.systemUptime }
    func stop() async throws -> [Int16] {
        stoppedDuration = duration; started = nil
        let count = Int(stoppedDuration * 48_000)
        return (0..<count).map { Int16(sin(Double($0) * 2 * Double.pi * 440 / 48_000) * 1_000) }
    }
    func cancel() { started = nil; stoppedDuration = 0 }
}
#endif
