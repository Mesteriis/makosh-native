#if DEBUG
import Foundation
import AVFoundation
import CoreVideo

/// Own synthetic media only. Called after an explicit QA download, never on render.
/// Opus is twelve seconds of generated silence encoded once with ffmpeg/libopus;
/// ffmpeg is not a product/build/runtime dependency.
enum TelegramSyntheticPlaybackFixtures {
    static func write(kind: TelegramPlaybackKind, to url: URL) async throws {
        switch kind {
        case .voice:
            guard let data = Data(base64Encoded: opus) else { throw TelegramPlaybackFileError.unsupported }
            try data.write(to: url)
        case .audio: try wave().write(to: url)
        case .video, .roundVideo: try await video(to: url)
        }
    }

    private static func wave() -> Data {
        let samples = 20 * 16000
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); word(UInt32(36 + samples * 2)); ascii("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(16000))
        word(UInt32(32000)); word(UInt16(2)); word(UInt16(16)); ascii("data"); word(UInt32(samples * 2))
        for sample in 0..<samples { word(Int16(sin(Double(sample) * 440 * 2 * .pi / 16000) * 500)) }
        return data
    }

    private static func video(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw TelegramPlaybackFileError.unsupported }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<240 {
                try Task.checkCancellation()
                var waits = 0
                while !input.isReadyForMoreMediaData {
                    guard waits < 500, writer.status == .writing else { throw TelegramPlaybackFileError.unsupported }
                    try await Task.sleep(for: .milliseconds(10)); waits += 1
                }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                      let buffer else { throw TelegramPlaybackFileError.unsupported }
                CVPixelBufferLockBaseAddress(buffer, [])
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                if let pixels = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                    for y in 0..<180 { for x in 0..<320 {
                        let offset = y * stride + x * 4
                        pixels[offset] = 255
                        pixels[offset + 1] = UInt8(30 + frame % 180)
                        pixels[offset + 2] = UInt8(50 + x / 2)
                        pixels[offset + 3] = UInt8(60 + y)
                    } }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 20)) else {
                    throw TelegramPlaybackFileError.unsupported
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw TelegramPlaybackFileError.unsupported }
        } catch { writer.cancelWriting(); throw error }
    }
    private static let opus = "T2dnUwACAAAAAAAAAABgnkgyAAAAACl/c/sBE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAAAAAAAAAAAGCeSDIBAAAAuYSy/QE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAyAQAAABwAAABlbmNvZGVyPUxhdmM2My4xLjEwMiBsaWJvcHVzT2dnUwAAgLsAAAAAAABgnkgyAgAAAKoo9WoyBwYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYIC+Y7I6tgCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GT2dnUwAAAHcBAAAAAABgnkgyAwAAAJX2cbEyBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsZPZ2dTAACAMgIAAAAAAGCeSDIEAAAAvTZiBDIGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxk9nZ1MAAADuAgAAAAAAYJ5IMgUAAADiKODLMgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GT2dnUwAAgKkDAAAAAABgnkgyBgAAANsMLhkyBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsZPZ2dTAAAAZQQAAAAAAGCeSDIHAAAA0gW0oTIGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxk9nZ1MAAIAgBQAAAAAAYJ5IMggAAAA6+1eQMgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GT2dnUwAAANwFAAAAAABgnkgyCQAAACSyY9EyBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsZPZ2dTAACAlwYAAAAAAGCeSDIKAAAAB6zChTIGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxk9nZ1MAAABTBwAAAAAAYJ5IMgsAAAC5oZDmMgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GCAissw7GT2dnUwAAgA4IAAAAAABgnkgyDAAAAC4pLwAyBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsYICKyzDsZPZ2dTAAAAyggAAAAAAGCeSDINAAAAbM5r6jIGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxggIrLMOxk9nZ1MABDjLCAAAAAAAYJ5IMg4AAABY2Jq5AQYICKyzDsY="
}
#endif
