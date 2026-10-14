import Foundation
import AVFoundation
import CoreVideo

@MainActor final class TelegramNativeCallCameraSource: TelegramCallCameraSource {
    private let driver: CallCameraDriver
    init(authorization: @escaping @Sendable () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
         makeInput: @escaping @Sendable () throws -> AVCaptureDeviceInput = {
             guard let device = AVCaptureDevice.default(for: .video) else { throw CallCameraFailure.unavailable }
             return try AVCaptureDeviceInput(device: device)
         }) {
        driver = CallCameraDriver(authorization: authorization, makeInput: makeInput)
    }
    func start(output: @escaping @Sendable (CVPixelBuffer) -> Void, failure: @escaping @MainActor () -> Void) async -> Bool {
        await driver.start(output: output, failure: failure)
    }
    func stop(completed: @escaping @MainActor () -> Void) { driver.stop(completed: completed) }
    isolated deinit { driver.stop(completed: {}) }
}
private enum CallCameraFailure: Error { case unavailable, denied, cancelled }
private final class CallCameraDriver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "Makosh.call.camera.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "Makosh.call.camera.frames", qos: .userInitiated)
    private let authorization: @Sendable () -> Bool
    private let makeInput: @Sendable () throws -> AVCaptureDeviceInput
    private let lock = NSLock()
    private var cancelled = false, failed = false, started = false, cleanupQueued = false, cleanupComplete = false
    private var output: (@Sendable (CVPixelBuffer) -> Void)?
    private var failure: (@MainActor () -> Void)?
    private var completions: [@MainActor () -> Void] = []
    private var videoOutput: AVCaptureVideoDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var lastFrame: UInt64 = 0 // sampleQueue only
    init(authorization: @escaping @Sendable () -> Bool, makeInput: @escaping @Sendable () throws -> AVCaptureDeviceInput) {
        self.authorization = authorization; self.makeInput = makeInput
    }
    private func requireGrant() throws {
        guard !lock.withLock({ cancelled || failed }) else { throw CallCameraFailure.cancelled }
        guard authorization() else { throw CallCameraFailure.denied }
    }
    func start(output: @escaping @Sendable (CVPixelBuffer) -> Void, failure: @escaping @MainActor () -> Void) async -> Bool {
        let admitted = lock.withLock { () -> Bool in
            guard !started, !cancelled, !failed else { return false }
            started = true; self.output = output; self.failure = failure; return true
        }
        guard admitted else { return false }
        return await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                do { try configure(); continuation.resume(returning: true) }
                catch { cleanup(); continuation.resume(returning: false) }
            }
        }
    }
    private func configure() throws {
        try requireGrant()
        session.beginConfiguration()
        do {
            if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
            else if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
            try requireGrant()
            let input = try makeInput()
            guard session.canAddInput(input) else { throw CallCameraFailure.unavailable }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(output) else { throw CallCameraFailure.unavailable }
            session.addOutput(output); videoOutput = output
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
            }
            session.commitConfiguration()
            let center = NotificationCenter.default
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.didStopRunningNotification] {
                observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in self?.failOnce() })
            }
            let device = ObjectIdentifier(input.device)
            observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let value = notification.object as? AVCaptureDevice, ObjectIdentifier(value) == device else { return }; self?.failOnce()
            })
        } catch { session.commitConfiguration(); throw error }
        try requireGrant(); session.startRunning(); try requireGrant()
        guard session.isRunning else { throw CallCameraFailure.unavailable }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let frame = CMSampleBufferGetImageBuffer(sampleBuffer), telegramCallFrameAdmitted(frame) else { failOnce(); return }
        guard authorization() else { failOnce(); return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= lastFrame, now - lastFrame < 33_333_333 { return }; lastFrame = now
        let callback = lock.withLock { cancelled || failed ? nil : self.output }
        callback?(frame)
    }
    private func failOnce() {
        let callback = lock.withLock { () -> (@MainActor () -> Void)? in
            guard !cancelled, !failed else { return nil }; failed = true; return failure
        }
        if let callback { Task { @MainActor in callback() } }
    }
    func stop(completed: @escaping @MainActor () -> Void) {
        let decision = lock.withLock { () -> Int in
            if cleanupComplete { return 2 }
            cancelled = true; output = nil; failure = nil; completions.append(completed)
            guard !cleanupQueued else { return 0 }; cleanupQueued = true; return 1
        }
        if decision == 2 { Task { @MainActor in completed() }; return }
        guard decision == 1 else { return }
        sessionQueue.async { [self] in
            cleanup()
            sampleQueue.async { [self] in
                let callbacks = lock.withLock { () -> [@MainActor () -> Void] in
                    cleanupComplete = true; let values = completions; completions = []; return values
                }
                Task { @MainActor in for value in callbacks { value() } }
            }
        }
    }
    private func cleanup() {
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        session.beginConfiguration()
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration(); videoOutput = nil
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
