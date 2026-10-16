@preconcurrency import AVFoundation
import Foundation

struct WhatsAppVoiceSamples: Sendable {
  let limit: Int
  private var samples: [Int16] = []
  var count: Int { samples.count }
  var full: Bool { samples.count >= limit }
  mutating func append(_ values: [Int16]) {
    guard limit > 0, samples.count < limit else { return }
    samples.append(contentsOf: values.prefix(limit - samples.count))
  }
  mutating func take() -> [Int16] {
    let values = samples
    samples = []
    return values
  }
  mutating func clear() {
    samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
    samples = []
  }
}
public struct WhatsAppVoiceCaptureStatus: Sendable {
  public let samples: Int, full: Bool
  public var seconds: Int { samples / 48000 }
}
public actor WhatsAppVoiceCapture {
  private nonisolated let executor = MediaExecutor()
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }
  private var native: VoiceInput?
  public init() {}
  deinit {
    if let native {
      executor.queue.async {
        native.stop()
        native.clear()
      }
    }
  }
  public func start() throws {
    guard native == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw WhatsAppFailure.unavailable
    }
    let value = VoiceInput(queue: executor.queue)
    do {
      try value.start()
      native = value
    } catch {
      value.stop()
      value.clear()
      throw error
    }
  }
  public func status() -> WhatsAppVoiceCaptureStatus {
    native?.status() ?? .init(samples: 0, full: false)
  }
  public func finish() throws -> [Int16] {
    guard let value = native else { throw WhatsAppFailure.closed }
    native = nil
    value.stop()
    let samples = value.take()
    guard samples.count >= 24000 else { throw WhatsAppFailure.invalid }
    return samples
  }
  public func cancel() {
    native?.stop()
    native?.clear()
    native = nil
  }
}
private final class VoiceInput: @unchecked Sendable {
  private let queue: DispatchQueue, engine = AVAudioEngine(), lock = NSLock()
  private var samples = WhatsAppVoiceSamples(limit: 28_800_000)
  private var closed = false, stopping = false, hasTap = false
  init(queue: DispatchQueue) { self.queue = queue }
  func start() throws {
    let source = engine.inputNode.outputFormat(forBus: 0)
    guard source.sampleRate > 0, source.channelCount > 0,
      let destination = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: source, to: destination)
    else { throw WhatsAppFailure.unavailable }
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) {
      [weak self] buffer, _ in
      guard let self, !self.lock.withLock({ self.closed || self.samples.full }) else { return }
      let capacity = AVAudioFrameCount(
        ceil(Double(buffer.frameLength) * 48000 / source.sampleRate) + 16)
      guard capacity <= 192000,
        let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity)
      else { return }
      var supplied = false
      var error: NSError?
      converter.convert(to: output, error: &error) { _, state in
        if supplied {
          state.pointee = .noDataNow
          return nil
        }
        supplied = true
        state.pointee = .haveData
        return buffer
      }
      guard error == nil, let data = output.int16ChannelData?[0] else { return }
      let values = Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
      let stop = self.lock.withLock {
        guard !self.closed else { return false }
        self.samples.append(values)
        if self.samples.full && !self.stopping {
          self.stopping = true
          return true
        }
        return false
      }
      if stop { self.queue.async { [weak self] in self?.stop() } }
    }
    hasTap = true
    engine.prepare()
    try engine.start()
  }
  func status() -> WhatsAppVoiceCaptureStatus {
    lock.withLock { .init(samples: samples.count, full: samples.full) }
  }
  func stop() {
    lock.withLock { closed = true }
    if hasTap {
      engine.inputNode.removeTap(onBus: 0)
      hasTap = false
    }
    engine.stop()
  }
  func take() -> [Int16] { lock.withLock { samples.take() } }
  func clear() { lock.withLock { samples.clear() } }
}
