import AVFoundation

@MainActor final class TelegramSystemCallPermissions: TelegramCallPermissions {
    private let permission = TelegramRecordingPermissionRequest()
    func authorize(video: Bool) async -> Bool {
        await permission.authorize(kind: video ? .roundVideo : .voice, isCurrent: { !Task.isCancelled })
    }
    func isAuthorized(video: Bool) -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
            (!video || AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
    }
}
