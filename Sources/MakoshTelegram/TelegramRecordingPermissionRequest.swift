import AVFoundation

/// The model owns permission prompts; capture providers only check authorization.
@MainActor final class TelegramRecordingPermissionRequest {
    var status: (AVMediaType) -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: $0) }
    var request: (AVMediaType) async -> Bool = { type in
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: type) { continuation.resume(returning: $0) }
        }
    }
    func authorize(kind: TelegramRecordingKind, isCurrent: () -> Bool) async -> Bool {
        let types: [AVMediaType] = kind == .roundVideo ? [.video, .audio] : [.audio]
        for type in types {
            guard !Task.isCancelled, isCurrent() else { return false }
            switch status(type) {
            case .authorized: break
            case .notDetermined:
                guard await request(type), !Task.isCancelled, isCurrent() else { return false }
            default: return false
            }
        }
        return !Task.isCancelled && isCurrent()
    }
}
