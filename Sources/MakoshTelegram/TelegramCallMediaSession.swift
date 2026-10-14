import Foundation
import CoreVideo

@MainActor protocol TelegramCallNativeBridge: AnyObject {
    var videoOutput: @Sendable (CVPixelBuffer) -> Void { get }
    func stop()
    func setMuted(_ value: Bool) -> Bool
    func setVideo(_ value: Bool) -> Bool
    func receive(_ data: Data) -> Bool
}
@MainActor protocol TelegramCallCameraSource: AnyObject {
    func start(output: @escaping @Sendable (CVPixelBuffer) -> Void, failure: @escaping @MainActor () -> Void) async -> Bool
    func stop(completed: @escaping @MainActor () -> Void)
}
enum TelegramCallMediaEvent {
    case transportConnected, transportReconnecting, remoteVideo(Bool), videoFrame(CVPixelBuffer), localVideoFrame(CVPixelBuffer)
    case signaling(Data), failed(TelegramCallError)
}
/// Owns native device and camera retirement independently of the conversation UI.
@MainActor final class TelegramCallMediaSession {
    private let makeCamera: @MainActor () -> any TelegramCallCameraSource
    private let receive: @MainActor (TelegramCallMediaEvent) -> Bool
    private var core: (any TelegramCallNativeBridge)?
    private var camera: (any TelegramCallCameraSource)?
    private var cameraContext: UUID?
    private var nativeReleased = false, cameraReleased = true, stopping = false, finished = false
    private var changingVideo = false, video = false, connected = false
    private var completions: [@MainActor () -> Void] = []
    private var startup: Task<Void, Never>?
    private var retirement: TelegramCallMediaSession?
    private lazy var inbox = TelegramCallMediaInbox { [weak self] value in
        MainActor.assumeIsolated { self?.consume(value) }
    }
    init(makeCore: (TelegramCallMediaInbox) -> (any TelegramCallNativeBridge)?,
         makeCamera: @escaping @MainActor () -> any TelegramCallCameraSource, video: Bool,
         receive: @escaping @MainActor (TelegramCallMediaEvent) -> Bool) {
        self.makeCamera = makeCamera; self.receive = receive
        core = makeCore(inbox)
        guard core != nil else { nativeReleased = true; fail(); return }
        if video { startup = Task { [weak self] in _ = await self?.setVideo(true) } }
    }
    func stop(completed: @escaping @MainActor () -> Void) {
        if finished { completed(); return }
        completions.append(completed)
        guard !stopping else { return }
        stopping = true; retirement = self; startup?.cancel(); startup = nil
        connected = false; inbox.revoke(); core?.stop()
        stopCamera { [weak self] in self?.completeIfReleased() }
        completeIfReleased()
    }
    private func stopCamera(completed: @escaping @MainActor () -> Void) {
        cameraContext = nil
        guard let camera else { cameraReleased = true; completed(); return }
        camera.stop { [weak self] in
            guard let self else { return }
            self.camera = nil; self.cameraReleased = true; completed()
        }
    }
    private func completeIfReleased() {
        guard stopping, !finished, nativeReleased, cameraReleased else { return }
        finished = true; core = nil; camera = nil
        let values = completions; completions = []; retirement = nil
        for value in values { value() }
    }
    private func fail() { guard !stopping else { return }; _ = receive(.failed(.failed)); stop(completed: {}) }
    private func consume(_ value: TelegramCallMediaDelivery) {
        if case .released = value { nativeReleased = true; core = nil; completeIfReleased(); return }
        guard !stopping else { return }
        let event: TelegramCallMediaEvent
        switch value {
        case let .state(state):
            switch state {
            case 0: fail(); return
            case 1: return
            case 2: guard !connected else { return }; connected = true; event = .transportConnected
            case 3: guard connected else { return }; connected = false; event = .transportReconnecting
            default: fail(); return
            }
        case let .remoteVideo(enabled): event = .remoteVideo(enabled)
        case let .frame(frame): guard connected else { return }; event = .videoFrame(frame)
        case let .localFrame(frame): guard cameraContext != nil else { return }; event = .localVideoFrame(frame)
        case let .signaling(data): event = .signaling(data)
        case .failed: fail(); return
        case .released: return
        }
        if !receive(event) { stop(completed: {}) }
    }
    func receive(_ data: Data) -> Bool { !stopping && !data.isEmpty && data.count <= 65536 && core?.receive(data) == true }
    func setMuted(_ value: Bool) -> Bool { !stopping && core?.setMuted(value) == true }
    func setVideo(_ value: Bool) async -> Bool {
        guard !stopping, !changingVideo, let core else { return false }
        if video == value { return true }
        changingVideo = true
        defer { changingVideo = false }
        if !value {
            guard core.setVideo(false) else { return false }
            await withCheckedContinuation { continuation in stopCamera { continuation.resume() } }
            guard !stopping else { return false }; video = false; return true
        }
        let camera = makeCamera(), token = UUID(), output = core.videoOutput, inbox = inbox
        self.camera = camera; cameraContext = token; cameraReleased = false
        let ready = await camera.start(output: { frame in
            output(frame); inbox.enqueue(.localFrame(frame))
        }, failure: { [weak self] in
            guard let self, self.cameraContext == token else { return }; self.fail()
        })
        guard !stopping, cameraContext == token else { return false }
        guard ready, core.setVideo(true) else { fail(); return false }
        video = true; return true
    }
}
