#if DEBUG
import Foundation
import CoreVideo

@MainActor final class TelegramSyntheticCallPermissions: TelegramCallPermissions {
    func authorize(video: Bool) async -> Bool { true }
    func isAuthorized(video: Bool) -> Bool { true }
}
@MainActor private final class SyntheticCallRead: TelegramCallRequest { func cancel() {} }
@MainActor final class TelegramSyntheticCallProvider: TelegramCallProvider {
    let accountID: Int64 = 101
    private var incoming: [TelegramIncomingCall] = []
    private var observer: (@MainActor (Result<[TelegramIncomingCall], TelegramCallError>) -> Void)?
    func loadPeer(_ id: Int64, receive: @escaping @MainActor (Result<TelegramCallPeer, TelegramCallError>) -> Void) -> any TelegramCallRequest {
        receive(.success(.init(accountID: accountID, peerID: id, title: id == 42 ? "Synthetic Alice" : "Synthetic Bob", canVoice: true, canVideo: true, revision: String(repeating: "a", count: 64))))
        return SyntheticCallRead()
    }
    func observeIncoming(receive: @escaping @MainActor (Result<[TelegramIncomingCall], TelegramCallError>) -> Void) -> any TelegramCallRequest {
        observer = receive; receive(.success(incoming)); return SyntheticCallRead()
    }
    func ring(video: Bool) {
        incoming = [.init(id: UUID(), accountID: accountID, peerID: 43, title: "Synthetic Bob", isVideo: video)]
        observer?(.success(incoming))
    }
    func decline(incoming: TelegramIncomingCall) { self.incoming.removeAll { $0.id == incoming.id }; observer?(.success(self.incoming)) }
    func startOutgoing(basis: TelegramCallPeer, video: Bool, callID: UUID, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease {
        SyntheticCallLease(video: video, receive: receive)
    }
    func accept(incoming: TelegramIncomingCall, video: Bool, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease {
        decline(incoming: incoming); return SyntheticCallLease(video: video, receive: receive)
    }
}
@MainActor private final class SyntheticCallLease: TelegramCallLease {
    private let receive: @MainActor (TelegramCallEvent) -> Bool
    private var launch: Task<Void, Never>?, stopped = false
    init(video: Bool, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) {
        self.receive = receive
        launch = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, !self.stopped, receive(.committing), receive(.requesting(ringing: true)) else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !self.stopped, receive(.videoAvailability(true)), receive(.connecting(fingerprint: Data((0..<32).map(UInt8.init)))) else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !self.stopped, receive(.transportConnected) else { return }
            if video { self.frames() }
        }
    }
    private func frames() {
        var image: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &image) == kCVReturnSuccess, let image,
              CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { return }
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 0), 100, CVPixelBufferGetBytesPerRowOfPlane(image, 0) * 240)
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * 120)
        CVPixelBufferUnlockBaseAddress(image, [])
        _ = receive(.remoteVideo(true)); _ = receive(.videoFrame(image)); _ = receive(.localVideoFrame(image))
    }
    func stop(completed: @escaping @MainActor () -> Void) {
        stopped = true; launch?.cancel(); launch = nil
        Task { try? await Task.sleep(for: .milliseconds(100)); completed() }
    }
    func setMuted(_ value: Bool) -> Bool { !stopped }
    func setVideo(_ value: Bool) async -> Bool {
        guard !stopped else { return false }
        if value { frames() } else { _ = receive(.remoteVideo(false)) }
        return true
    }
}
#endif
