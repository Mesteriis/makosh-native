import Foundation
import CoreVideo
import AVFoundation
import CMakoshTelegramVoIP

struct TelegramCallCFunctions: Sendable {
    let create: @Sendable (UnsafePointer<MKCallConfig>, UnsafePointer<MKCallCallbacks>) -> OpaquePointer?
    let signal: @Sendable (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Int32
    let mute: @Sendable (OpaquePointer?, Int32) -> Int32
    let video: @Sendable (OpaquePointer?, Int32) -> Int32
    let push: @Sendable (OpaquePointer?, CVPixelBuffer) -> Int32
    let stop: @Sendable (OpaquePointer?) -> Void
    let destroy: @Sendable (OpaquePointer?) -> Void
    static let native = TelegramCallCFunctions(create: { config, callbacks in
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              config.pointee.video == 0 || AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return nil }
        return mk_call_create(config, callbacks)
    }, signal: { mk_call_receive_signaling($0, $1, $2) }, mute: { mk_call_set_muted($0, $1) },
    video: { mk_call_set_video($0, $1) }, push: { mk_call_push_video($0, $1) }, stop: { mk_call_stop($0) }, destroy: { mk_call_destroy($0) })
}
@MainActor final class TelegramCallCBridge: TelegramCallNativeBridge {
    private let endpoint: CallNativeEndpoint
    init?(configuration: TelegramCallMediaConfiguration, inbox: TelegramCallMediaInbox, functions: TelegramCallCFunctions = .native,
          nativeQueue: DispatchQueue = DispatchQueue(label: "Makosh.call.native", qos: .userInitiated)) {
        guard callConfigurationAdmitted(configuration) else { return nil }
        endpoint = CallNativeEndpoint(configuration: configuration, inbox: inbox, functions: functions, queue: nativeQueue)
    }
    isolated deinit { endpoint.stop() }
    var videoOutput: @Sendable (CVPixelBuffer) -> Void { { [weak endpoint] frame in endpoint?.enqueue(frame) } }
    func stop() { endpoint.stop() }
    func setMuted(_ value: Bool) -> Bool { endpoint.setMuted(value) }
    func setVideo(_ value: Bool) -> Bool { endpoint.setVideo(value) }
    func receive(_ data: Data) -> Bool { endpoint.receive(data) }
}
private func callCallback(_ context: UnsafeMutableRawPointer?) -> CallNativeEndpoint? {
    context.map { Unmanaged<CallNativeEndpoint>.fromOpaque($0).takeUnretainedValue() }
}
private func callCString<T>(_ value: String, into target: inout T) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count < MemoryLayout<T>.size, !bytes.contains(0) else { return false }
    withUnsafeMutableBytes(of: &target) { raw in raw.initializeMemory(as: UInt8.self, repeating: 0); raw.copyBytes(from: bytes) }
    return true
}
private func callConfigurationAdmitted(_ configuration: TelegramCallMediaConfiguration) -> Bool {
    func fits(_ value: String, _ capacity: Int) -> Bool { value.utf8.count < capacity && !value.utf8.contains(0) }
    guard configuration.audioDevices.isValid, configuration.key.count == 256,
          fits(configuration.audioDevices.inputUID, 128), fits(configuration.audioDevices.outputUID, 128), fits(configuration.version, 16),
          !configuration.servers.isEmpty, configuration.servers.count <= 32,
          configuration.servers.allSatisfy({ fits($0.host, 256) && fits($0.username, 256) && fits($0.password, 256) }) else { return false }
    if let proxy = configuration.proxy {
        guard case let .socks5(username, password) = proxy.connection,
              fits(proxy.host, 256), fits(username ?? "", 256), fits(password ?? "", 256) else { return false }
    }
    return true
}
/// The actor only admits bounded commands. Native creation, controls, frames,
/// stop and destruction run FIFO on this worker, including callback-driven release.
private final class CallNativeEndpoint: @unchecked Sendable {
    private enum Command: Sendable { case mute(Bool), video(Bool), signal(Data) }
    private let queue: DispatchQueue
    private let lock = NSLock()
    // Admission/frame state only. Never hold this lock across a C call or delivery.
    private var accepting = true, stopRequested = false, nativeReleased = false
    private var controls = 0, signals = 0, signalingBytes = 0
    private var frame: CVPixelBuffer?, frameScheduled = false
    private let functions: TelegramCallCFunctions
    private let inbox: TelegramCallMediaInbox
    // Worker-owned lifetime state. The C context retains this endpoint until the
    // real released callback has been serialized behind every in-flight C call.
    private var handle: OpaquePointer?, context: UnsafeMutableRawPointer?
    private var stopIssued = false, releaseFinished = false
    init(configuration: TelegramCallMediaConfiguration, inbox: TelegramCallMediaInbox, functions: TelegramCallCFunctions, queue: DispatchQueue) {
        self.functions = functions; self.inbox = inbox; self.queue = queue
        queue.async { [self] in start(configuration) }
    }
    private func start(_ configuration: TelegramCallMediaConfiguration) {
        guard lock.withLock({ accepting }) else { finishRelease(); return }
        var config = MKCallConfig()
        config.abi_version = 2; config.outgoing = configuration.outgoing ? 1 : 0
        config.video = configuration.video ? 1 : 0; config.allow_p2p = configuration.allowP2P ? 1 : 0; config.max_layer = configuration.maxLayer
        guard callCString(configuration.audioDevices.inputUID, into: &config.audio_input_uid),
              callCString(configuration.audioDevices.outputUID, into: &config.audio_output_uid),
              callCString(configuration.version, into: &config.version) else { fail(); finishRelease(); return }
        withUnsafeMutableBytes(of: &config.key) { $0.copyBytes(from: configuration.key) }
        var servers: [MKCallServer] = []
        for value in configuration.servers {
            var server = MKCallServer(); server.port = value.port; server.id = value.id
            server.turn = value.turn ? 1 : 0; server.tcp = value.tcp ? 1 : 0
            guard callCString(value.host, into: &server.host), callCString(value.username, into: &server.username),
                  callCString(value.password, into: &server.password) else { fail(); finishRelease(); return }
            servers.append(server)
        }
        if let proxy = configuration.proxy {
            guard case let .socks5(username, password) = proxy.connection else { fail(); finishRelease(); return }
            config.use_proxy = 1; config.proxy_port = proxy.port
            guard callCString(proxy.host, into: &config.proxy_host), callCString(username ?? "", into: &config.proxy_username),
                  callCString(password ?? "", into: &config.proxy_password) else { fail(); finishRelease(); return }
        }
        context = Unmanaged.passRetained(self).toOpaque()
        var callback = MKCallCallbacks(); callback.context = context
        callback.state = { context, value in
            guard let endpoint = callCallback(context) else { return }
            if value == 0 { endpoint.fail() } else { endpoint.deliver(.state(value)) }
        }
        callback.remote_video = { context, value in callCallback(context)?.deliver(.remoteVideo(value != 0)) }
        callback.signaling = { context, bytes, size in
            guard let endpoint = callCallback(context) else { return }
            guard let bytes, size > 0, size <= 65536 else { endpoint.fail(); return }
            endpoint.deliver(.signaling(Data(bytes: bytes, count: size)))
        }
        callback.video_frame = { context, frame in
            guard let endpoint = callCallback(context) else { return }
            guard let frame else { endpoint.fail(); return }; endpoint.deliver(.frame(frame))
        }
        callback.released = { context in callCallback(context)?.released() }
        handle = servers.withUnsafeBufferPointer { buffer in
            config.servers = buffer.baseAddress; config.server_count = buffer.count
            return functions.create(&config, &callback)
        }
        guard handle != nil else {
            // The ABI guarantees nil schedules no callbacks and owns no device.
            // Release means startup retired, never successful native creation.
            fail(); finishRelease(); return
        }
        if lock.withLock({ !accepting && !nativeReleased }) { stopNative() }
    }
    // True reports bounded queue admission, not a native success acknowledgement.
    // A later native rejection follows the existing failure inbox path, state(0).
    func setMuted(_ value: Bool) -> Bool { admit(.mute(value)) }
    func setVideo(_ value: Bool) -> Bool { admit(.video(value)) }
    func receive(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 65536 else { return false }
        return admit(.signal(data))
    }
    private func admit(_ command: Command) -> Bool {
        let decision = lock.withLock { () -> (admitted: Bool, overflow: Bool) in
            guard accepting else { return (false, false) }
            switch command {
            case let .signal(data):
                guard signals < 256, signalingBytes + data.count <= 1024 * 1024 else { return (false, true) }
                signals += 1; signalingBytes += data.count
            case .mute, .video:
                guard controls < 32 else { return (false, true) }; controls += 1
            }
            queue.async { [self] in execute(command) }
            return (true, false)
        }
        if decision.overflow { fail() }
        return decision.admitted
    }
    private func execute(_ command: Command) {
        defer { lock.withLock {
            switch command {
            case let .signal(data): signals -= 1; signalingBytes -= data.count
            case .mute, .video: controls -= 1
            }
        } }
        guard lock.withLock({ accepting }), let handle else { return }
        let result: Int32
        switch command {
        case let .mute(value): result = functions.mute(handle, value ? 1 : 0)
        case let .video(value): result = functions.video(handle, value ? 1 : 0)
        case let .signal(data): result = data.withUnsafeBytes { functions.signal(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        }
        if result == 0 { fail() }
    }
    func enqueue(_ value: CVPixelBuffer) {
        guard telegramCallFrameAdmitted(value) else { return }
        lock.withLock {
            guard accepting else { return }; frame = value
            guard !frameScheduled else { return }; frameScheduled = true
            queue.async { [self] in drainFrame() }
        }
    }
    private func drainFrame() {
        let value = lock.withLock { () -> CVPixelBuffer? in
            let value = frame; frame = nil; frameScheduled = false; return accepting ? value : nil
        }
        if let handle, let value, functions.push(handle, value) == 0 { fail() }
    }
    private func deliver(_ value: TelegramCallMediaDelivery) {
        guard lock.withLock({ accepting }) else { return }; inbox.enqueue(value)
    }
    private func fail() {
        let notify = lock.withLock { () -> Bool in
            guard accepting else { return false }; accepting = false; frame = nil; return true
        }
        guard notify else { return }; inbox.enqueue(.state(0)); requestStop()
    }
    func stop() {
        lock.withLock { accepting = false; frame = nil }
        inbox.revoke(); requestStop()
    }
    private func requestStop() {
        lock.withLock {
            guard !stopRequested else { return }; stopRequested = true
            queue.async { [self] in stopNative() }
        }
    }
    private func stopNative() {
        guard !stopIssued, !releaseFinished, let handle, !lock.withLock({ nativeReleased }) else { return }
        stopIssued = true; functions.stop(handle)
    }
    private func released() {
        lock.withLock {
            guard !nativeReleased else { return }; nativeReleased = true; accepting = false; frame = nil
            queue.async { [self] in finishRelease() }
        }
    }
    private func finishRelease() {
        guard !releaseFinished else { return }; releaseFinished = true
        if let handle { self.handle = nil; functions.destroy(handle) }
        inbox.release()
        if let context { self.context = nil; Unmanaged<CallNativeEndpoint>.fromOpaque(context).release() }
    }
}
