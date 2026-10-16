import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
// H264 Annex-B workflow adapted from WhatsApp Zen Video.swift (MIT).
// Each call owns its sessions and serial queues; no platform media singleton.
import Foundation
@preconcurrency import VideoToolbox

final class WhatsAppH264Codec: @unchecked Sendable {
  static func validDimensions(width:Int,height:Int)->Bool {width>0 && height>0 && max(width,height)<=1920 && min(width,height)<=1080}
  private let tileSize:CGSize?
  private var resetting=false
  private let queue: DispatchQueue
  init(
    queue: DispatchQueue = DispatchQueue(label: "Makosh.whatsapp.call.codec", qos: .userInteractive),tileSize:CGSize?=nil
  ) { self.queue = queue;self.tileSize=tileSize }
  private let lock = NSLock()
  private var closed = false, encoding = false
  private var decoding = false, rendering = false
  private var pendingDecode: (Data, UInt8)?, pendingKey: (Data, UInt8)?
  private var pendingRender: (PixelFrame, UInt8)?
  var pendingDecodeCount: Int {
    lock.withLock { (pendingDecode == nil ? 0 : 1) + (pendingKey == nil ? 0 : 1) }
  }
  private var latest: (CVPixelBuffer, CMTime)?
  private var encoded: (@Sendable (Data) -> Void)?, decoded: (@Sendable (CGImage) -> Void)?
  private var encoder: VTCompressionSession?, decoder: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var sps: Data?, pps: Data?
  private var context: CIContext?
  var onEncoded: (@Sendable (Data) -> Void)? {
    get { lock.withLock { encoded } }
    set { lock.withLock { encoded = newValue } }
  }
  var onDecoded: (@Sendable (CGImage) -> Void)? {
    get { lock.withLock { decoded } }
    set { lock.withLock { decoded = newValue } }
  }
  func encode(_ image: CVPixelBuffer, time: CMTime) {
    let schedule = lock.withLock {
      guard !closed else { return false }
      latest = (image, time)
      if encoding { return false }
      encoding = true
      return true
    }
    if schedule { queue.async { [self] in encodeLatest() } }
  }
  private func encodeLatest() {
    let input = lock.withLock {
      let value = latest
      latest = nil
      return value
    }
    guard let (image, time) = input else {
      lock.withLock { encoding = false }
      return
    }
    if encoder == nil {
      var session: VTCompressionSession?
      let status = VTCompressionSessionCreate(
        allocator: nil, width: Int32(CVPixelBufferGetWidth(image)),
        height: Int32(CVPixelBufferGetHeight(image)), codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
      if status == noErr, let session {
        encoder = session
        VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_ProfileLevel,
          value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
        VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_AverageBitRate, value: 600_000 as CFNumber)
        VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 15 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
      }
    }
    if let encoder {
      VTCompressionSessionEncodeFrame(
        encoder, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
        frameProperties: nil, infoFlagsOut: nil
      ) { [weak self] status, _, sample in
        guard let self, status == noErr, let sample, let data = Self.annexB(sample),
          data.count <= 256 * 1024
        else { return }
        let callback = self.lock.withLock { self.closed ? nil : self.encoded }
        callback?(data)
      }
    }
    let again = lock.withLock {
      if closed || latest == nil {
        encoding = false
        return false
      }
      return true
    }
    if again { queue.async { [self] in encodeLatest() } }
  }
  func decode(_ data: Data, orientation: UInt8 = 0) {
    guard !data.isEmpty, data.count <= 256 * 1024, orientation <= 3 else { return }
    let key = Self.units(data).contains { [5, 7].contains(Int(($0.first ?? 0) & 31)) }
    let schedule = lock.withLock {
      guard !closed,!resetting else { return false }
      if key {
        pendingKey = (data, orientation)
        pendingDecode = nil
      } else {
        pendingDecode = (data, orientation)
      }
      if decoding { return false }
      decoding = true
      return true
    }
    if schedule { queue.async { [self] in decodeLatest() } }
  }
  private func decodeLatest() {
    let item = lock.withLock { () -> (Data, UInt8)? in
      guard !closed else {
        decoding = false
        return nil
      }
      if let key = pendingKey {
        pendingKey = nil
        return key
      }
      let value = pendingDecode
      pendingDecode = nil
      if value == nil { decoding = false }
      return value
    }
    guard let (data, orientation) = item else { return }
    decodeOnQueue(data, orientation: orientation)
    queue.async { [self] in decodeLatest() }
  }
  private func decodeOnQueue(_ data: Data, orientation: UInt8) {
    guard !lock.withLock({ closed || resetting }) else { return }
    let nals = Self.units(data)
    guard !nals.isEmpty, nals.count <= 256 else { return }
    let newSPS = nals.last { ($0.first ?? 0) & 31 == 7 }
    let newPPS = nals.last { ($0.first ?? 0) & 31 == 8 }
    if let newSPS, let newPPS, sps != newSPS || pps != newPPS {
      if let decoder {
        VTDecompressionSessionInvalidate(decoder)
        self.decoder = nil
      }
      format = nil
      sps = newSPS
      pps = newPPS
      newSPS.withUnsafeBytes { a in
        newPPS.withUnsafeBytes { b in
          guard let pa = a.bindMemory(to: UInt8.self).baseAddress,
            let pb = b.bindMemory(to: UInt8.self).baseAddress
          else { return }
          let pointers = [pa, pb]
          let sizes = [a.count, b.count]
          pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { n in
              _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: 2, parameterSetPointers: p.baseAddress!,
                parameterSetSizes: n.baseAddress!, nalUnitHeaderLength: 4,
                formatDescriptionOut: &format)
            }
          }
        }
      }
    }
    guard let format else { return }
    let dimensions=CMVideoFormatDescriptionGetDimensions(format)
    guard Self.validDimensions(width:Int(dimensions.width),height:Int(dimensions.height)) else {self.format=nil;return}
    if decoder == nil {
      var created: VTDecompressionSession?
      let status = VTDecompressionSessionCreate(
        allocator: nil, formatDescription: format, decoderSpecification: nil,
        imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
          as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
      guard status == noErr else { return }
      decoder = created
    }
    var bytes = Data()
    for unit in nals where ![7, 8, 9].contains(Int((unit.first ?? 0) & 31)) {
      var size = UInt32(unit.count).bigEndian
      withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }
      bytes.append(unit)
    }
    guard !bytes.isEmpty else { return }
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
        blockBufferOut: &block) == kCMBlockBufferNoErr, let block
    else { return }
    let copied = bytes.withUnsafeBytes { p in
      CMBlockBufferReplaceDataBytes(
        with: p.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
    }
    guard copied == kCMBlockBufferNoErr else { return }
    var sample: CMSampleBuffer?
    var size = bytes.count
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    guard
      CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample, let decoder
    else { return }
    VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      [weak self] status, _, image, _, _ in
      guard status == noErr, let image, let self else { return }
      self.render(image, orientation: orientation)
    }
    VTDecompressionSessionWaitForAsynchronousFrames(decoder)
  }
  private func render(_ image: CVPixelBuffer, orientation: UInt8) {
    // The decompressor callback enters without actor inheritance. Conversion
    // is serialized with codec work, and UI receives an immutable CGImage.
    let schedule = lock.withLock {
      guard !closed,!resetting else { return false }
      pendingRender = (PixelFrame(image), orientation)
      if rendering { return false }
      rendering = true
      return true
    }
    if schedule { queue.async { [self] in renderLatest() } }
  }
  private func renderLatest() {
    let frame = lock.withLock {
      let value = pendingRender
      pendingRender = nil
      rendering = false
      return closed || resetting ? nil : value
    }
    guard let (frame, orientation) = frame else { return }
    var ci = CIImage(cvPixelBuffer: frame.value).oriented(
      [.up, .right, .down, .left][Int(orientation)])
    if let tileSize {let scale=min(1,tileSize.width/ci.extent.width,tileSize.height/ci.extent.height);ci=ci.transformed(by:CGAffineTransform(scaleX:scale,y:scale))}
    let context = self.context ?? CIContext(options: [.cacheIntermediates: false])
    self.context = context
    if let image = context.createCGImage(ci, from: ci.extent) {
      let callback = lock.withLock { closed || resetting ? nil : decoded }
      callback?(image)
    }
  }

  func resetDecoder() async {
    lock.withLock {resetting=true;pendingDecode=nil;pendingKey=nil;pendingRender=nil}
    await withCheckedContinuation {continuation in queue.async { [self] in
      if let decoder {VTDecompressionSessionWaitForAsynchronousFrames(decoder);VTDecompressionSessionInvalidate(decoder)}
      decoder=nil;format=nil;sps=nil;pps=nil;context=nil
      lock.withLock {resetting=false};continuation.resume()
    }}
  }
  func stop() async {
    lock.withLock {
      closed = true
      latest = nil
      pendingDecode = nil
      pendingKey = nil
      pendingRender = nil
      encoded = nil
      decoded = nil
    }
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if let encoder {
          VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
          VTCompressionSessionInvalidate(encoder)
        }
        if let decoder {
          VTDecompressionSessionWaitForAsynchronousFrames(decoder)
          VTDecompressionSessionInvalidate(decoder)
        }
        encoder = nil
        decoder = nil
        format = nil
        sps = nil
        pps = nil
        context = nil
        continuation.resume()
      }
    }
  }
  private struct PixelFrame: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
  }
  static func units(_ data: Data) -> [Data] {
    var result: [Data] = []
    var start: Int?
    var zeros = 0
    for index in data.indices {
      let byte = data[index]
      if byte == 0 {
        zeros += 1
      } else {
        if byte == 1, zeros >= 2 {
          if let start {
            let end = index - min(zeros, 3)
            if end > start { result.append(Data(data[start..<end])) }
          }
          start = index + 1
        }
        zeros = 0
      }
    }
    if let start, start < data.endIndex { result.append(Data(data[start..<data.endIndex])) }
    return result
  }
  static func annexB(_ sample: CMSampleBuffer) -> Data? {
    guard let block = CMSampleBufferGetDataBuffer(sample),
      let format = CMSampleBufferGetFormatDescription(sample)
    else { return nil }
    var out = Data()
    var length = 0
    var pointer: UnsafeMutablePointer<CChar>?
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[CFString: Any]], attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
    {
      for index in 0..<2 {
        var p: UnsafePointer<UInt8>?
        var size = 0
        guard
          CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &p,
            parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            == noErr, let p
        else { return nil }
        out.append(contentsOf: [0, 0, 0, 1])
        out.append(p, count: size)
      }
    }
    guard
      CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
        dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer, length <= 256 * 1024
    else { return nil }
    let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
    var offset = 0
    while offset + 4 <= length {
      let size =
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
        | Int(bytes[offset + 3])
      offset += 4
      guard size > 0, size <= length - offset else { return nil }
      out.append(contentsOf: [0, 0, 0, 1])
      out.append(contentsOf: bytes[offset..<offset + size])
      offset += size
    }
    guard offset == length else { return nil }
    return out
  }
}
