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
    init?(configuration: TelegramCallMediaConfiguration, inbox: TelegramCallMediaInbox, functions: TelegramCallCFunctions = .native) {
        endpoint = CallNativeEndpoint(configuration: configuration, inbox: inbox, functions: functions)
        guard endpoint.isAvailable else { return nil }
    }
    isolated deinit { endpoint.stop() }
    var videoOutput: @Sendable (CVPixelBuffer) -> Void { { [weak endpoint] frame in endpoint?.enqueue(frame) } }
    func stop() { endpoint.stop() }
    func setMuted(_ value: Bool) -> Bool { endpoint.setMuted(value) }
    func setVideo(_ value: Bool) -> Bool { endpoint.setVideo(value) }
    func receive(_ data: Data) -> Bool { endpoint.receive(data) }
}
private final class CallNativeCallbacks: @unchecked Sendable {
    let inbox: TelegramCallMediaInbox
    private let functions: TelegramCallCFunctions
    private let lock = NSLock()
    private var handle: OpaquePointer?, finished = false
    init(inbox: TelegramCallMediaInbox, functions: TelegramCallCFunctions) { self.inbox = inbox; self.functions = functions }
    func attach(_ handle: OpaquePointer) { lock.withLock { self.handle = handle } }
    func release() -> Bool {
        let result = lock.withLock { () -> (Bool, OpaquePointer?) in
            guard !finished else { return (false, nil) }; finished = true; let value = handle; handle = nil; return (true, value)
        }
        guard result.0 else { return false }
        if let handle = result.1 { functions.destroy(handle) }
        inbox.release(); return true
    }
}
private func callCallback(_ context: UnsafeMutableRawPointer?) -> CallNativeCallbacks? {
    context.map { Unmanaged<CallNativeCallbacks>.fromOpaque($0).takeUnretainedValue() }
}
private func callCString<T>(_ value: String, into target: inout T) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count < MemoryLayout<T>.size, !bytes.contains(0) else { return false }
    withUnsafeMutableBytes(of: &target) { raw in raw.initializeMemory(as: UInt8.self, repeating: 0); raw.copyBytes(from: bytes) }
    return true
}
/// Every C call for this handle is serialized. Camera producers retain only one latest frame.
private final class CallNativeEndpoint: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Makosh.call.native", qos: .userInitiated)
    private let frameLock = NSLock()
    private var frame: CVPixelBuffer?, frameScheduled = false, framesClosed = false
    private let functions: TelegramCallCFunctions
    private let callbacks: CallNativeCallbacks
    private var handle: OpaquePointer?, stopped = false
    var isAvailable: Bool { queue.sync { handle != nil && !stopped } }
    init(configuration: TelegramCallMediaConfiguration, inbox: TelegramCallMediaInbox, functions: TelegramCallCFunctions) {
        self.functions = functions; callbacks = CallNativeCallbacks(inbox: inbox, functions: functions)
        queue.sync {
            var config = MKCallConfig()
            config.abi_version = 2; config.outgoing = configuration.outgoing ? 1 : 0
            config.video = configuration.video ? 1 : 0; config.allow_p2p = configuration.allowP2P ? 1 : 0
            config.max_layer = configuration.maxLayer
            guard configuration.audioDevices.isValid,
                  callCString(configuration.audioDevices.inputUID, into: &config.audio_input_uid),
                  callCString(configuration.audioDevices.outputUID, into: &config.audio_output_uid),
                  callCString(configuration.version, into: &config.version), configuration.key.count == 256 else { return }
            withUnsafeMutableBytes(of: &config.key) { $0.copyBytes(from: configuration.key) }
            var servers: [MKCallServer] = []
            for value in configuration.servers {
                var server = MKCallServer(); server.port = value.port; server.id = value.id
                server.turn = value.turn ? 1 : 0; server.tcp = value.tcp ? 1 : 0
                guard callCString(value.host, into: &server.host), callCString(value.username, into: &server.username),
                      callCString(value.password, into: &server.password) else { return }
                servers.append(server)
            }
            if let proxy = configuration.proxy {
                guard case let .socks5(username, password) = proxy.connection else { return }
                config.use_proxy = 1; config.proxy_port = proxy.port
                guard callCString(proxy.host, into: &config.proxy_host), callCString(username ?? "", into: &config.proxy_username),
                      callCString(password ?? "", into: &config.proxy_password) else { return }
            }
            let retained = Unmanaged.passRetained(callbacks).toOpaque()
            var callback = MKCallCallbacks(); callback.context = retained
            callback.state = { context, value in callCallback(context)?.inbox.enqueue(.state(value)) }
            callback.remote_video = { context, value in callCallback(context)?.inbox.enqueue(.remoteVideo(value != 0)) }
            callback.signaling = { context, bytes, size in
                guard let box = callCallback(context) else { return }
                guard let bytes, size > 0, size <= 65536 else { box.inbox.enqueue(.state(0)); return }
                box.inbox.enqueue(.signaling(Data(bytes: bytes, count: size)))
            }
            callback.video_frame = { context, frame in
                guard let box = callCallback(context) else { return }
                guard let frame else { box.inbox.enqueue(.state(0)); return }; box.inbox.enqueue(.frame(frame))
            }
            callback.released = { context in
                guard let context, let box = callCallback(context) else { return }
                if box.release() { Unmanaged<CallNativeCallbacks>.fromOpaque(context).release() }
            }
            handle = servers.withUnsafeBufferPointer { buffer in
                config.servers = buffer.baseAddress; config.server_count = buffer.count
                return functions.create(&config, &callback)
            }
            if let handle { callbacks.attach(handle) } else { Unmanaged<CallNativeCallbacks>.fromOpaque(retained).release() }
        }
    }
    func setMuted(_ value: Bool) -> Bool { queue.sync { !stopped && handle != nil && functions.mute(handle, value ? 1 : 0) != 0 } }
    func setVideo(_ value: Bool) -> Bool { queue.sync { !stopped && handle != nil && functions.video(handle, value ? 1 : 0) != 0 } }
    func receive(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 65536 else { return false }
        return queue.sync {
            guard !stopped, let handle else { return false }
            return data.withUnsafeBytes { functions.signal(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) != 0 }
        }
    }
    func enqueue(_ value: CVPixelBuffer) {
        guard telegramCallFrameAdmitted(value) else { return }
        let schedule = frameLock.withLock { () -> Bool in
            guard !framesClosed else { return false }; frame = value
            let needed = !frameScheduled; frameScheduled = true; return needed
        }
        if schedule { queue.async { [self] in drainFrame() } }
    }
    private func drainFrame() {
        let value = frameLock.withLock { () -> CVPixelBuffer? in
            let value = frame; frame = nil; frameScheduled = false; return framesClosed ? nil : value
        }
        if !stopped, let handle, let value, functions.push(handle, value) == 0 { callbacks.inbox.enqueue(.state(0)) }
    }
    func stop() {
        frameLock.withLock { framesClosed = true; frame = nil }
        queue.sync {
            guard !stopped else { return }; stopped = true
            if let handle { functions.stop(handle) }
        }
    }
}
