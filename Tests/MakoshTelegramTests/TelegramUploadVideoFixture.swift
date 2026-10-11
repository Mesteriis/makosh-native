import XCTest
import AVFoundation
import CoreVideo
@testable import MakoshTelegram

@MainActor
func writeUploadVideoFixture(_ url: URL, rotated: Bool = false, timescale: Int32 = 10, width: Int = 32, height: Int = 16) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
    ])
    if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    guard writer.startWriting() else { throw TelegramPlaybackFileError.unsupported }
    writer.startSession(atSourceTime: .zero)
    do {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 0, CVPixelBufferGetBytesPerRow(pixels) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<10 {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                guard waits < 500, writer.status == .writing else { throw TelegramPlaybackFileError.unsupported }
                try await Task.sleep(for: .milliseconds(10)); waits += 1
            }
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: timescale)) else {
                throw TelegramPlaybackFileError.unsupported
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    } catch { writer.cancelWriting(); throw error }
}
