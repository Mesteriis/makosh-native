import Foundation
import AVFoundation
import AudioToolbox

@MainActor public protocol TelegramRoundVideoCapture: AnyObject {
    func start() async throws
    func stop() async throws -> Data
    func cancel()
    var duration: Double { get }
    var level: Float { get }
    var isRecording: Bool { get }
    var previewSession: AVCaptureSession? { get }
}

enum TelegramRoundVideoCaptureError: Error, Equatable, Sendable {
    case permissionDenied, unavailable, invalidState, invalidSample, invalidRecording, backpressure
}

@MainActor protocol TelegramRoundVideoCaptureSource: AnyObject {
    var previewSession: AVCaptureSession? { get }
    func start(writer: TelegramRoundVideoCaptureWriter) async throws
    func stop() async
    func cancel()
}

/// One-shot recording. Construction is inert; the caller owns both permission prompts.
@MainActor public final class TelegramCameraRoundVideoCapture: TelegramRoundVideoCapture {
    private let authorization: () -> (AVAuthorizationStatus, AVAuthorizationStatus)
    private let makeSource: () -> any TelegramRoundVideoCaptureSource
    private let startupTimeout: Double
    private let captureTimeout: Double
    private let audioStallTimeout: Double
    private var used = false
    private var cancelled = false
    private var starting = false
    private var active = false
    private var sourceReady = false
    private var formatsReady = false
    private var failure: (any Error)?
    private var retained: Data?
    private var source: (any TelegramRoundVideoCaptureSource)?
    private var writer: TelegramRoundVideoCaptureWriter?
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var sourceTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var finishTask: Task<Data, any Error>?

    public convenience init() throws {
        self.init(authorization: { (AVCaptureDevice.authorizationStatus(for: .video), AVCaptureDevice.authorizationStatus(for: .audio)) },
                  makeSource: { TelegramNativeRoundVideoSource() })
    }
    init(authorization: @escaping () -> (AVAuthorizationStatus, AVAuthorizationStatus),
         makeSource: @escaping () -> any TelegramRoundVideoCaptureSource,
         startupTimeout: Double = 10, captureTimeout: Double = 60, audioStallTimeout: Double = 2) {
        self.authorization = authorization; self.makeSource = makeSource
        self.startupTimeout = max(0, min(startupTimeout, 10))
        self.captureTimeout = max(0, min(captureTimeout, 60))
        self.audioStallTimeout = max(0, min(audioStallTimeout, 2))
    }
    public var duration: Double { writer?.snapshot.duration ?? 0 }
    public var level: Float { active ? writer?.snapshot.level ?? 0 : 0 }
    public var isRecording: Bool { active && (writer?.snapshot.isRecording ?? false) }
    public var previewSession: AVCaptureSession? { starting || active ? source?.previewSession : nil }

    public func start() async throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
        guard !used else { throw TelegramRoundVideoCaptureError.invalidState }
        used = true
        let grants = authorization()
        guard grants.0 == .authorized, grants.1 == .authorized else {
            failure = TelegramRoundVideoCaptureError.permissionDenied
            throw TelegramRoundVideoCaptureError.permissionDenied
        }
        let writer = try TelegramRoundVideoCaptureWriter()
        self.writer = writer
        let source = makeSource(); self.source = source
        starting = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingStart = continuation
                sourceTask = Task { [weak self, source, writer] in
                    do { try await source.start(writer: writer); self?.becameReady(source: true) }
                    catch { self?.failStart(error) }
                }
                readinessTask = Task { [weak self, writer] in
                    do { try await writer.waitUntilReady(timeout: self?.startupTimeout ?? 0); self?.becameReady(source: false) }
                    catch { self?.failStart(error) }
                }
                let timeout = startupTimeout
                deadlineTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)); self?.failStart(TelegramRoundVideoCaptureError.unavailable) }
                    catch {}
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        if cancelled { throw CancellationError() }
    }
    private func becameReady(source: Bool) {
        guard starting, !cancelled, pendingStart != nil else { return }
        if source { sourceReady = true } else { formatsReady = true }
        guard sourceReady, formatsReady else { return }
        starting = false; active = true
        deadlineTask?.cancel(); deadlineTask = nil
        let continuation = pendingStart; pendingStart = nil; continuation?.resume()
        let started = ProcessInfo.processInfo.systemUptime
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard let self, self.active, !self.cancelled, let writer = self.writer else { return }
                let snapshot = writer.snapshot, now = ProcessInfo.processInfo.systemUptime
                if !snapshot.isRecording || now - started >= self.captureTimeout ||
                    (snapshot.lastAudioHostTime > 0 && now - snapshot.lastAudioHostTime >= self.audioStallTimeout) {
                    do { _ = try await self.stop() } catch {}
                    return
                }
            }
        }
    }
    private func failStart(_ error: any Error) {
        guard starting else { return }
        starting = false; active = false; failure = cancelled ? CancellationError() : error
        deadlineTask?.cancel(); readinessTask?.cancel(); sourceTask?.cancel()
        source?.cancel(); source = nil; writer?.cancel()
        let continuation = pendingStart; pendingStart = nil
        continuation?.resume(throwing: failure!)
    }
    public func stop() async throws -> Data {
        if cancelled { throw CancellationError() }
        if let retained { return retained }
        if let failure { throw failure }
        guard used, !starting, let writer else { throw TelegramRoundVideoCaptureError.invalidState }
        active = false; watchdogTask?.cancel(); watchdogTask = nil
        if finishTask == nil {
            let source = self.source; self.source = nil
            finishTask = Task {
                // Normal completion drains an entered append; cancellation would
                // propagate through the async writer and destroy valid output.
                await source?.stop()
                try Task.checkCancellation()
                return try await writer.finish()
            }
        }
        do {
            let bytes = try await finishTask!.value
            if cancelled { throw CancellationError() }
            retained = bytes; return bytes
        } catch { failure = cancelled ? CancellationError() : error; throw failure! }
    }
    public func cancel() {
        cancelled = true; active = false; retained = nil
        if starting { failStart(CancellationError()) }
        sourceTask?.cancel(); readinessTask?.cancel(); deadlineTask?.cancel(); watchdogTask?.cancel(); finishTask?.cancel()
        source?.cancel(); source = nil; writer?.cancel()
    }
    isolated deinit {
        sourceTask?.cancel(); readinessTask?.cancel(); deadlineTask?.cancel(); watchdogTask?.cancel(); finishTask?.cancel()
        source?.cancel(); writer?.cancel()
    }
}

@MainActor private final class TelegramNativeRoundVideoSource: TelegramRoundVideoCaptureSource {
    private let driver = TelegramRoundVideoCaptureDriver()
    var previewSession: AVCaptureSession? { driver.session }
    func start(writer: TelegramRoundVideoCaptureWriter) async throws { try await driver.start(writer: writer) }
    func stop() async { driver.cancel() }
    func cancel() { driver.cancel() }
}

/// No device is selected until start. Session configuration never blocks the main actor.
private final class TelegramRoundVideoCaptureDriver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "Makosh.round-video.session", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var writer: TelegramRoundVideoCaptureWriter?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var isCancelled: Bool { lock.withLock { cancelled } }
    private func requireGrants() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw TelegramRoundVideoCaptureError.permissionDenied
        }
        if isCancelled { throw CancellationError() }
    }
    func start(writer: TelegramRoundVideoCaptureWriter) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                sessionQueue.async {
                    do { try self.configure(writer: writer); continuation.resume() }
                    catch { self.cleanup(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }
    private func configure(writer: TelegramRoundVideoCaptureWriter) throws {
        try requireGrants()
        session.beginConfiguration()
        do {
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            else if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
            guard let camera = AVCaptureDevice.default(for: .video), let microphone = AVCaptureDevice.default(for: .audio) else {
                throw TelegramRoundVideoCaptureError.unavailable
            }
            try requireGrants() // Immediately before constructing each permission-sensitive input.
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(cameraInput) else { throw TelegramRoundVideoCaptureError.unavailable }
            session.addInput(cameraInput)
            try requireGrants()
            let microphoneInput = try AVCaptureDeviceInput(device: microphone)
            guard session.canAddInput(microphoneInput) else { throw TelegramRoundVideoCaptureError.unavailable }
            session.addInput(microphoneInput)
            let v = AVCaptureVideoDataOutput(), a = AVCaptureAudioDataOutput()
            v.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            v.alwaysDiscardsLateVideoFrames = true
            a.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            guard session.canAddOutput(v), session.canAddOutput(a) else { throw TelegramRoundVideoCaptureError.unavailable }
            session.addOutput(v); session.addOutput(a)
            if let connection = v.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
            }
            lock.withLock { self.writer = writer }; videoOutput = v; audioOutput = a
            v.setSampleBufferDelegate(self, queue: writer.sampleQueue)
            a.setSampleBufferDelegate(self, queue: writer.sampleQueue)
            session.commitConfiguration()
        } catch { session.commitConfiguration(); throw error }
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.didStopRunningNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self, !self.isCancelled else { return }; writer.fail(); self.cancel()
            })
        }
        // Captured on sessionQueue once; notification threads never inspect mutable inputs.
        let monitoredDevices = Set(session.inputs.compactMap { ($0 as? AVCaptureDeviceInput).map { ObjectIdentifier($0.device) } })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, !self.isCancelled, let device = notification.object as? AVCaptureDevice,
                  monitoredDevices.contains(ObjectIdentifier(device)) else { return }
            writer.fail(); self.cancel()
        })
        try requireGrants()
        session.startRunning()
        if isCancelled { throw CancellationError() }
        guard session.isRunning else { throw TelegramRoundVideoCaptureError.unavailable }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isCancelled, let writer = lock.withLock({ self.writer }) else { return }
        do {
            if output is AVCaptureVideoDataOutput {
                guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { writer.fail(); cancel(); return }
                try writer.consumeVideo(pixels, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            } else { try writer.consumeAudio(sampleBuffer) }
        } catch TelegramRoundVideoCaptureError.backpressure { /* Drop one real-time sample rather than queueing an unbounded backlog. */ }
        catch TelegramRoundVideoCaptureError.invalidState { /* A retained 60-second result is already finishing. */ }
        catch { writer.fail(); cancel() }
    }
    func cancel() {
        let first = lock.withLock { if cancelled { return false }; cancelled = true; return true }
        if first { sessionQueue.async { self.cleanup() } }
    }
    private func cleanup() {
        videoOutput?.setSampleBufferDelegate(nil, queue: nil); audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        session.beginConfiguration()
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        videoOutput = nil; audioOutput = nil
        // The delegate's writer reference is immutable while callbacks are active. Cancellation
        // rejects late callbacks before they can touch its terminal writer state.
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
