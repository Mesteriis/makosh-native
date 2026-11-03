import Foundation
import CoreFoundation
import CoreGraphics
import ImageIO
import zlib
import MakoshCustomEmojiControl

public struct TelegramCustomEmojiAnimationInfo: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frameDurations: [Double]
    public var frameCount: Int { frameDurations.count }
}
public struct TelegramCustomEmojiFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// A tightly packed, premultiplied BGRA8 surface on the supported host.
    public let pixels: Data
}

// The handle is only used by its owning decoder actor. ARC keeps it alive until
// the last synchronous native call returns; destruction cannot overlap a call.
private final class TelegramCustomEmojiLottieHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { makosh_emoji_lottie_destroy(pointer) }
}

public actor TelegramCustomEmojiAnimationDecoder {
    public nonisolated let info: TelegramCustomEmojiAnimationInfo
    private let vector: TelegramCustomEmojiLottieHandle?
    private let imageSource: CGImageSource?
    private let video: TelegramCustomEmojiWebMDecoder?

    public init(bytes: Data, format: TelegramCustomEmojiFormat) throws {
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024 else { throw TelegramCustomEmojiError.invalid }
        switch format {
        case .tgs:
            let json = try TelegramCustomEmojiVectorInput.validatedJSON(bytes)
            var native = MakoshEmojiLottieInfo()
            let pointer = json.withUnsafeBytes { buffer in
                makosh_emoji_lottie_create(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &native)
            }
            guard let pointer else { throw TelegramCustomEmojiError.invalid }
            let handle = TelegramCustomEmojiLottieHandle(pointer)
            self.vector = handle; self.imageSource = nil; self.video = nil
            self.info = .init(width: Int(native.width), height: Int(native.height),
                frameDurations: Array(repeating: 1 / native.frame_rate, count: Int(native.frame_count)))
        case .webP:
            guard bytes.count >= 12, bytes.prefix(4) == Data("RIFF".utf8), bytes[8..<12] == Data("WEBP".utf8) else {
                throw TelegramCustomEmojiError.invalid
            }
            let declared = (4..<8).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << UInt32(($1 - 4) * 8) }
            guard UInt64(declared) + 8 == UInt64(bytes.count) else { throw TelegramCustomEmojiError.invalid }
            let (source, dimensions) = try TelegramUploadWebPIO.validatedSource(bytes)
            guard dimensions.width <= 512, dimensions.height <= 512 else { throw TelegramCustomEmojiError.invalid }
            let count = CGImageSourceGetCount(source)
            var durations: [Double] = []
            for index in 0..<count {
                try Task.checkCancellation()
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let webP = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                let value = webP?[kCGImagePropertyWebPUnclampedDelayTime] ?? webP?[kCGImagePropertyWebPDelayTime]
                if count == 1 { durations.append(1) }
                else {
                    guard let delay = (value as? NSNumber)?.doubleValue, delay.isFinite, delay > 0, delay <= 9 else {
                        throw TelegramCustomEmojiError.invalid
                    }
                    durations.append(delay)
                }
            }
            guard durations.reduce(0, +) <= 9 else { throw TelegramCustomEmojiError.invalid }
            self.vector = nil; self.imageSource = source; self.video = nil
            self.info = .init(width: Int(dimensions.width), height: Int(dimensions.height), frameDurations: durations)
        case .webM:
            let video = try TelegramCustomEmojiWebMDecoder(bytes: bytes)
            self.vector = nil; self.imageSource = nil; self.video = video
            self.info = video.info
        }
        try Task.checkCancellation()
    }

    public func frame(index: Int, width: Int, height: Int) throws -> TelegramCustomEmojiFrame {
        try Task.checkCancellation()
        guard index >= 0, index < info.frameCount, (1...512).contains(width), (1...512).contains(height) else {
            throw TelegramCustomEmojiError.invalid
        }
        if let video { return try video.frame(index: index, width: width, height: height) }
        var pixels = Data(count: width * height * 4)
        if let vector {
            let status = pixels.withUnsafeMutableBytes { buffer in
                makosh_emoji_lottie_render(vector.pointer, UInt32(index), UInt32(width), UInt32(height),
                    buffer.bindMemory(to: UInt8.self).baseAddress, width * 4, buffer.count)
            }
            guard status == 0 else { throw TelegramCustomEmojiError.invalid }
        } else if let source = imageSource {
            guard let image = CGImageSourceCreateImageAtIndex(source, index,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width == info.width, image.height == info.height,
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                throw TelegramCustomEmojiError.invalid
            }
            try pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                    throw TelegramCustomEmojiError.invalid
                }
                let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
                let w = Double(image.width) * scale, h = Double(image.height) * scale
                context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
            }
        } else { throw TelegramCustomEmojiError.invalid }
        try Task.checkCancellation()
        return .init(width: width, height: height, pixels: pixels)
    }
}

private enum TelegramCustomEmojiVectorInput {
    static func validatedJSON(_ bytes: Data) throws -> Data {
        let data = bytes.starts(with: [0x1f, 0x8b]) ? try unzip(bytes) : bytes
        // RLottie's shape parser consumes fields after their type tag. Keep
        // the original member order, while rejecting ambiguous duplicate keys
        // before either semantic parser can choose a different value.
        var keys = TelegramCustomEmojiVectorJSONKeys(bytes: Array(data))
        try keys.validate()
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = number(root["w"]), let height = number(root["h"]),
              let rate = number(root["fr"]), let start = number(root["ip"]), let end = number(root["op"]),
              width > 0, height > 0, width <= 1536, height <= 1536,
              width.rounded(.towardZero) == width, height.rounded(.towardZero) == height,
              rate > 0, rate <= 360, start >= 0, end > start, end - start <= rate * 9,
              (end - start).rounded(.towardZero) == end - start,
              root["layers"] is [Any] else { throw TelegramCustomEmojiError.invalid }
        if let assets = root["assets"] {
            guard let entries = assets as? [[String: Any]],
                  entries.allSatisfy({ $0["p"] == nil && $0["u"] == nil }) else { throw TelegramCustomEmojiError.invalid }
        }
        var stack: [(Any, Int)] = [(root, 0)], nodes = 0
        while let (value, depth) = stack.popLast() {
            try Task.checkCancellation()
            nodes += 1
            guard depth <= 64, nodes <= 200_000 else { throw TelegramCustomEmojiError.invalid }
            if let object = value as? [String: Any] {
                // Native vector expressions and external raster assets have no
                // supported renderer path; preserve the Unicode fallback.
                guard !(object["x"] is String) else { throw TelegramCustomEmojiError.invalid }
                stack.append(contentsOf: object.values.map { ($0, depth + 1) })
            } else if let array = value as? [Any] {
                stack.append(contentsOf: array.map { ($0, depth + 1) })
            } else if let numeric = value as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID() {
                guard numeric.doubleValue.isFinite else { throw TelegramCustomEmojiError.invalid }
            }
        }
        return data
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func unzip(_ data: Data) throws -> Data {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        guard inflateInit2_(stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TelegramCustomEmojiError.invalid
        }
        defer { inflateEnd(stream) }
        return try data.withUnsafeBytes { input in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(input.count)
            defer { stream.pointee.next_in = nil }
            var result = Data()
            while true {
                try Task.checkCancellation()
                var chunk = Data(count: 65_536)
                let before = stream.pointee.avail_in
                let (status, produced) = chunk.withUnsafeMutableBytes { output -> (Int32, Int) in
                    stream.pointee.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.pointee.avail_out = uInt(output.count)
                    defer { stream.pointee.next_out = nil }
                    let status = inflate(stream, Z_NO_FLUSH)
                    return (status, output.count - Int(stream.pointee.avail_out))
                }
                guard status == Z_OK || status == Z_STREAM_END,
                      produced <= 8 * 1024 * 1024 - result.count,
                      status == Z_STREAM_END || produced > 0 || stream.pointee.avail_in < before else {
                    throw TelegramCustomEmojiError.invalid
                }
                chunk.count = produced; result.append(chunk)
                if status == Z_STREAM_END {
                    guard stream.pointee.avail_in == 0 else { throw TelegramCustomEmojiError.invalid }
                    return result
                }
            }
        }
    }
}

// This bounded structural pass only tracks object member names. Foundation
// remains responsible for complete JSON syntax and semantic decoding.
private struct TelegramCustomEmojiVectorJSONKeys {
    let bytes: [UInt8]
    private var cursor = 0
    private var nodes = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard cursor == bytes.count else { throw TelegramCustomEmojiError.invalid }
    }

    private mutating func value(depth: Int) throws {
        try Task.checkCancellation()
        nodes += 1
        whitespace()
        guard depth <= 64, nodes <= 200_000, cursor < bytes.count else {
            throw TelegramCustomEmojiError.invalid
        }
        switch bytes[cursor] {
        case 0x7b: // object
            cursor += 1
            whitespace()
            if consume(0x7d) { return }
            var names: Set<Data> = []
            while true {
                whitespace()
                let range = try string()
                guard let name = try JSONSerialization.jsonObject(with: Data(bytes[range]),
                    options: [.fragmentsAllowed]) as? String,
                      !name.utf8.contains(0),
                      names.insert(Data(name.utf8)).inserted else { throw TelegramCustomEmojiError.invalid }
                whitespace()
                guard consume(0x3a) else { throw TelegramCustomEmojiError.invalid }
                try value(depth: depth + 1)
                whitespace()
                if consume(0x7d) { return }
                guard consume(0x2c) else { throw TelegramCustomEmojiError.invalid }
            }
        case 0x5b: // array
            cursor += 1
            whitespace()
            if consume(0x5d) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if consume(0x5d) { return }
                guard consume(0x2c) else { throw TelegramCustomEmojiError.invalid }
            }
        case 0x22:
            _ = try string()
        default:
            let start = cursor
            while cursor < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[cursor]) {
                cursor += 1
            }
            guard cursor > start else { throw TelegramCustomEmojiError.invalid }
        }
    }

    private mutating func string() throws -> Range<Int> {
        let start = cursor
        guard consume(0x22) else { throw TelegramCustomEmojiError.invalid }
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            if byte == 0x22 { return start..<cursor }
            if byte == 0x5c {
                guard cursor < bytes.count else { throw TelegramCustomEmojiError.invalid }
                cursor += 1
            }
        }
        throw TelegramCustomEmojiError.invalid
    }

    private mutating func whitespace() {
        while cursor < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[cursor]) { cursor += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard cursor < bytes.count, bytes[cursor] == byte else { return false }
        cursor += 1
        return true
    }
}
