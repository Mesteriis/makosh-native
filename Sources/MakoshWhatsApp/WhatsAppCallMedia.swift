@preconcurrency import AVFoundation
import CoreAudio
import CoreImage
import Foundation

public struct WhatsAppCallDevice: Identifiable, Equatable, Sendable {
  public let id: String, name: String
}
public struct WhatsAppCallDeviceList: Sendable {
  public let inputs: [WhatsAppCallDevice], outputs: [WhatsAppCallDevice],
    cameras: [WhatsAppCallDevice]
}
public struct WhatsAppCallDeviceSelection: Sendable, Equatable {
  public var input: String = "", output: String = "", camera: String = ""
  public init() {}
}
public struct WhatsAppCallMediaInput: Sendable { public var audio: [[Int16]], video: [UInt8] }
public struct WhatsAppCallImages: @unchecked Sendable {
  public var local: CGImage?, remote: CGImage?
  public init(local: CGImage?, remote: CGImage?) {
    self.local = local
    self.remote = remote
  }
}
public protocol WhatsAppCallMediaServing: Sendable {
  func start(selection: WhatsAppCallDeviceSelection, video: Bool) async throws
  func setVideo(_ on: Bool) async throws
  func setGroupVideoMode() async
  func setMuted(_ on: Bool) async
  func input() async throws -> WhatsAppCallMediaInput
  func receive(_ output: WhatsAppCallOutput) async
  func images() async -> WhatsAppCallImages
  func stop() async
}
extension WhatsAppCallMediaServing {public func setGroupVideoMode() async {}}
final class MediaExecutor: SerialExecutor, @unchecked Sendable {
  let queue = DispatchQueue(label: "Makosh.whatsapp.call.media", qos: .userInteractive)
  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}
public actor WhatsAppCallMedia: WhatsAppCallMediaServing {
  private nonisolated let executor = MediaExecutor()
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }
  private var native: CallDevices?
  public init() {}
  public func start(selection: WhatsAppCallDeviceSelection, video: Bool) async throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      !video || AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    else { throw WhatsAppFailure.notAdmitted }
    guard native == nil else { throw WhatsAppFailure.invalid }
    let owned = CallDevices(queue: executor.queue, selection: selection)
    do {
      try owned.start(video: video)
      native = owned
    } catch {
      owned.stopDevices()
      await owned.codec.stop()
      throw error
    }
  }
  public func setVideo(_ on: Bool) throws {
    guard let native else { throw WhatsAppFailure.closed }
    try native.setVideo(on)
  }
  public func setGroupVideoMode() async {guard let owned=native else {return};owned.beginGroupVideo();await owned.codec.resetDecoder()}
  public func setMuted(_ on: Bool) { native?.setMuted(on) }
  public func input() throws -> WhatsAppCallMediaInput {
    guard let native, native.healthy else { throw WhatsAppFailure.unavailable }
    return native.input()
  }
  public func receive(_ output: WhatsAppCallOutput) { native?.receive(output) }
  public func images() -> WhatsAppCallImages { native?.images() ?? .init(local: nil, remote: nil) }
  public func stop() async {
    guard let owned = native else { return }
    native = nil
    owned.stopDevices()
    await owned.codec.stop()
  }
  public func devices() -> WhatsAppCallDeviceList { Self.enumerateDevices() }
  private static func enumerateDevices() -> WhatsAppCallDeviceList {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var inputs: [WhatsAppCallDevice] = []
    var outputs: [WhatsAppCallDevice] = []
    if AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    {
      var devices = Array(
        repeating: AudioDeviceID(0), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
      if AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
      {
        for id in devices {
          var retainedName: Unmanaged<CFString>?
          var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
          var title = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
          guard AudioObjectGetPropertyData(id, &title, 0, nil, &nameSize, &retainedName) == noErr,
            let name = retainedName?.takeRetainedValue()
          else { continue }
          for (scope, input) in [
            (kAudioDevicePropertyScopeInput, true), (kAudioDevicePropertyScopeOutput, false),
          ] {
            var property = AudioObjectPropertyAddress(
              mSelector: kAudioDevicePropertyStreams, mScope: scope,
              mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr, bytes > 0 {
              let value = WhatsAppCallDevice(id: String(id), name: name as String)
              if input { inputs.append(value) } else { outputs.append(value) }
            }
          }
        }
      }
    }
    let cameras = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
    ).devices.map { WhatsAppCallDevice(id: $0.uniqueID, name: $0.localizedName) }
    return .init(inputs: inputs, outputs: outputs, cameras: cameras)
  }
}

/// Device objects are touched only on the media executor. The audio/video
/// callbacks are born outside MainActor and share only the bounded locked inbox.
private final class CallDevices: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  let codec = WhatsAppH264Codec()
  private let queue: DispatchQueue, selection: WhatsAppCallDeviceSelection
  private let engine = AVAudioEngine(), player = AVAudioPlayerNode(), camera = AVCaptureSession()
  private let lock = NSLock()
  private var pcm = WhatsAppPCMFrames(), video = Data(), local: CGImage?, remote: CGImage?
  private var groupVideo=false
  private var closed = false, muted = false, videoEnabled = false, scheduled = 0, hasTap = false
  private var converter: AVAudioConverter?
  private var lastVideoTime = CMTime.invalid
  private var context: CIContext?
  init(queue: DispatchQueue, selection: WhatsAppCallDeviceSelection) {
    self.queue = queue
    self.selection = selection
    super.init()
    codec.onEncoded = { [weak self] data in
      self?.lock.withLock {
        guard let self, !self.closed, self.videoEnabled else { return }
        self.video = data
      }
    }
    codec.onDecoded = { [weak self] image in
      self?.lock.withLock {
        guard let self, !self.closed,!self.groupVideo else { return }
        self.remote = image
      }
    }
  }
  func start(video: Bool) throws {
    try device(engine.inputNode.audioUnit, id: selection.input)
    try device(engine.outputNode.audioUnit, id: selection.output)
    let source = engine.inputNode.outputFormat(forBus: 0)
    guard source.sampleRate > 0, source.channelCount > 0,
      let destination = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: source, to: destination),
      let playback = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    else { throw WhatsAppFailure.unavailable }
    self.converter = converter
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: playback)
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) {
      [weak self] buffer, _ in
      self?.captureAudio(buffer, converter: converter, destination: destination)
    }
    hasTap = true
    engine.prepare()
    try engine.start()
    player.play()
    if video { try setVideo(true) }
  }
  private func device(_ unit: AudioUnit?, id: String) throws {
    guard !id.isEmpty else { return }
    guard let unit, var device = AudioDeviceID(id) else { throw WhatsAppFailure.invalid }
    guard
      AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
        UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    else { throw WhatsAppFailure.unavailable }
  }
  private func captureAudio(
    _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, destination: AVAudioFormat
  ) {
    guard !lock.withLock({ closed || muted }) else { return }
    let capacity = AVAudioFrameCount(
      ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 16)
    guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else {
      return
    }
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let data = output.int16ChannelData?[0], output.frameLength <= 192000 else {
      return
    }
    let values = Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    lock.withLock { if !closed && !muted { pcm.append(values) } }
  }
  func setVideo(_ on: Bool) throws {
    if !on {
      lock.withLock {
        videoEnabled = false
        video = Data()
        local = nil
      }
      if camera.isRunning { camera.stopRunning() }
      return
    }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      throw WhatsAppFailure.notAdmitted
    }
    if camera.inputs.isEmpty {
      let device =
        selection.camera.isEmpty
        ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: selection.camera)
      guard let device else { throw WhatsAppFailure.unavailable }
      let input = try AVCaptureDeviceInput(device: device)
      let output = AVCaptureVideoDataOutput()
      guard camera.canAddInput(input), camera.canAddOutput(output) else {
        throw WhatsAppFailure.unavailable
      }
      camera.beginConfiguration()
      camera.sessionPreset = .vga640x480
      camera.addInput(input)
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ]
      output.alwaysDiscardsLateVideoFrames = true
      output.setSampleBufferDelegate(self, queue: queue)
      camera.addOutput(output)
      camera.commitConfiguration()
    }
    lock.withLock { videoEnabled = true }
    camera.startRunning()
    guard camera.isRunning else {
      lock.withLock { videoEnabled = false }
      throw WhatsAppFailure.unavailable
    }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sample: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !lock.withLock({ closed || !videoEnabled }),
      let image = CMSampleBufferGetImageBuffer(sample)
    else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    if lastVideoTime.isValid, CMTimeGetSeconds(CMTimeSubtract(time, lastVideoTime)) < 1 / 15.5 {
      return
    }
    lastVideoTime = time
    codec.encode(image, time: time)
    let ci = CIImage(cvPixelBuffer: image)
    let context = self.context ?? CIContext(options: [.cacheIntermediates: false])
    self.context = context
    if let image = context.createCGImage(ci, from: ci.extent) {
      lock.withLock { if !closed { local = image } }
    }
  }
  func setMuted(_ value: Bool) {
    lock.withLock {
      muted = value
      if value { pcm = WhatsAppPCMFrames() }
    }
  }
  var healthy: Bool { engine.isRunning && (!lock.withLock { videoEnabled } || camera.isRunning) }
  func input() -> WhatsAppCallMediaInput {
    lock.withLock {
      let audio = pcm.take()
      let frame = video
      video = Data()
      return .init(audio: audio, video: Array(frame))
    }
  }
  func beginGroupVideo() {lock.withLock {groupVideo=true;remote=nil}}
  func images() -> WhatsAppCallImages { lock.withLock { .init(local: local, remote: remote) } }
  func receive(_ output: WhatsAppCallOutput) {
    if !lock.withLock({groupVideo}),let video = output.video, !video.isEmpty {
      codec.decode(Data(video), orientation: output.orientation)
    }
    for frame in output.audio where !frame.isEmpty && frame.count <= 1920 {
      let allowed = lock.withLock {
        guard !closed, scheduled < 3 else { return false }
        scheduled += 1
        return true
      }
      guard allowed else { continue }
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.count)),
        let data = buffer.floatChannelData?[0]
      else {
        lock.withLock { scheduled -= 1 }
        continue
      }
      buffer.frameLength = AVAudioFrameCount(frame.count)
      for index in frame.indices { data[index] = Float(frame[index]) / 32768 }
      player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
        self?.lock.withLock {
          guard let self, !self.closed else { return }
          self.scheduled = max(0, self.scheduled - 1)
        }
      }
    }
  }
  func stopDevices() {
    lock.withLock {
      closed = true
      pcm = WhatsAppPCMFrames()
      video = Data()
      local = nil
      remote = nil
      scheduled = 0
    }
    if hasTap {
      engine.inputNode.removeTap(onBus: 0)
      hasTap = false
    }
    player.stop()
    engine.stop()
    if camera.isRunning { camera.stopRunning() }
    converter = nil
    context = nil
  }
}
