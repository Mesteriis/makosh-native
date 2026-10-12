import Foundation
import CoreGraphics
import MakoshCustomEmojiControl

// One actor owns this state. No native call crosses an actor suspension point;
// destruction waits for the last synchronous decode to return.
final class TelegramCustomEmojiWebMDecoder: @unchecked Sendable {
    let info: TelegramCustomEmojiAnimationInfo
    private let movie: TelegramCustomEmojiWebM
    private let visiblePackets: [Int]
    private var handle: TelegramCustomEmojiVP9Handle
    private var nextPacket = 0
    private var lastVisible: Int?
    private var canvas: Data

    init(bytes: Data) throws {
        let movie = try TelegramCustomEmojiWebM(bytes: bytes)
        let probe = try TelegramCustomEmojiVP9Handle(movie: movie)
        var canvas = Data(count: movie.width * movie.height * 4)
        var visible: [Int] = []
        for (index, packet) in movie.packets.enumerated() {
            try Task.checkCancellation()
            let status = try probe.decode(packet: packet, canvas: &canvas, width: movie.width)
            if status == 0 && !packet.invisible { visible.append(index) }
        }
        guard let first = visible.first, let last = visible.last else { throw TelegramCustomEmojiError.invalid }
        var durations: [Double] = []
        for position in 0..<visible.count {
            let packet = movie.packets[visible[position]]
            let duration: Double
            if position + 1 < visible.count {
                duration = movie.packets[visible[position + 1]].time - packet.time
            } else if let explicit = packet.duration ?? movie.defaultDuration {
                duration = explicit
            } else if let declared = movie.declaredDuration {
                duration = declared - packet.time
            } else { throw TelegramCustomEmojiError.invalid }
            guard duration.isFinite, duration > 0, duration <= 9 else { throw TelegramCustomEmojiError.invalid }
            durations.append(duration)
        }
        let length = durations.reduce(0, +)
        let end = movie.packets[last].time + (durations.last ?? 0)
        guard length.isFinite, length > 0, length <= 9,
              end - movie.packets[first].time <= 9,
              movie.declaredDuration.map({ end <= $0 + 0.000_001 }) ?? true else {
            throw TelegramCustomEmojiError.invalid
        }
        self.movie = movie; self.visiblePackets = visible
        self.info = .init(width: movie.width, height: movie.height, frameDurations: durations)
        self.handle = try TelegramCustomEmojiVP9Handle(movie: movie)
        self.canvas = Data(count: movie.width * movie.height * 4)
        try Task.checkCancellation()
    }

    func frame(index: Int, width: Int, height: Int) throws -> TelegramCustomEmojiFrame {
        try Task.checkCancellation()
        guard visiblePackets.indices.contains(index), (1...512).contains(width), (1...512).contains(height) else {
            throw TelegramCustomEmojiError.invalid
        }
        if lastVisible != index {
            let target = visiblePackets[index]
            if target < nextPacket {
                handle = try TelegramCustomEmojiVP9Handle(movie: movie)
                nextPacket = 0; lastVisible = nil
            }
            while nextPacket <= target {
                try Task.checkCancellation()
                let packet = movie.packets[nextPacket]
                let status = try handle.decode(packet: packet, canvas: &canvas, width: movie.width)
                if nextPacket == target {
                    guard status == 0, !packet.invisible else { throw TelegramCustomEmojiError.invalid }
                }
                nextPacket += 1
            }
            lastVisible = index
        }
        try Task.checkCancellation()
        if width == movie.width, height == movie.height {
            return .init(width: width, height: height, pixels: canvas)
        }
        guard let provider = CGDataProvider(data: canvas as CFData),
              let image = CGImage(width: movie.width, height: movie.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: movie.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw TelegramCustomEmojiError.invalid
        }
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw TelegramCustomEmojiError.invalid
            }
            let scale = min(Double(width) / Double(movie.width), Double(height) / Double(movie.height))
            let w = Double(movie.width) * scale, h = Double(movie.height) * scale
            context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        }
        try Task.checkCancellation()
        return .init(width: width, height: height, pixels: pixels)
    }
}

private final class TelegramCustomEmojiVP9Handle {
    let pointer: OpaquePointer
    init(movie: TelegramCustomEmojiWebM) throws {
        guard let pointer = makosh_emoji_vp9_create(UInt32(movie.width), UInt32(movie.height), movie.hasAlpha ? 1 : 0) else {
            throw TelegramCustomEmojiError.invalid
        }
        self.pointer = pointer
    }
    deinit { makosh_emoji_vp9_destroy(pointer) }
    func decode(packet: TelegramCustomEmojiWebMPacket, canvas: inout Data, width: Int) throws -> Int32 {
        let status = packet.color.withUnsafeBytes { color in
            (packet.alpha ?? Data()).withUnsafeBytes { alpha in
                canvas.withUnsafeMutableBytes { output in
                    makosh_emoji_vp9_decode(pointer, color.bindMemory(to: UInt8.self).baseAddress, color.count,
                        alpha.bindMemory(to: UInt8.self).baseAddress, alpha.count,
                        output.bindMemory(to: UInt8.self).baseAddress, width * 4, output.count)
                }
            }
        }
        guard status == 0 || status == 1 else { throw TelegramCustomEmojiError.invalid }
        return status
    }
}
