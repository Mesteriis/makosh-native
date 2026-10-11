import Foundation

/// Own synthetic GIF89a encoder: four literal palette colors, with a dictionary
/// reset before each pixel. No reference assets, codec package or account data.
struct UploadGIFTestFrame {
    var color: UInt8
    var delay: UInt16?
    var x: UInt16 = 0
    var y: UInt16 = 0
    var width: UInt16 = 32
    var height: UInt16 = 16
    var disposal: UInt8 = 1
}

func uploadGIFFixture(_ frames: [UploadGIFTestFrame], width: UInt16 = 32, height: UInt16 = 16) -> Data {
    var result = Data("GIF89a".utf8)
    func word(_ value: UInt16) { result.append(UInt8(value & 255)); result.append(UInt8(value >> 8)) }
    word(width); word(height)
    result.append(contentsOf: [0xf1, 0, 0, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255])
    for frame in frames {
        if let delay = frame.delay {
            result.append(contentsOf: [0x21, 0xf9, 4, frame.disposal << 2])
            word(delay); result.append(contentsOf: [0, 0])
        }
        result.append(0x2c); word(frame.x); word(frame.y); word(frame.width); word(frame.height)
        result.append(contentsOf: [0, 2])
        var compressed = Data(), bits: UInt32 = 0, count = 0
        func code(_ value: UInt32) {
            bits |= value << count; count += 3
            while count >= 8 { compressed.append(UInt8(bits & 255)); bits >>= 8; count -= 8 }
        }
        for _ in 0..<(Int(frame.width) * Int(frame.height)) { code(4); code(UInt32(frame.color)) }
        code(5)
        if count > 0 { compressed.append(UInt8(bits & 255)) }
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + 255, compressed.count)
            result.append(UInt8(end - offset)); result.append(compressed[offset..<end]); offset = end
        }
        result.append(0)
    }
    result.append(0x3b)
    return result
}

let uploadGIFTimingFixture = uploadGIFFixture([
    .init(color: 1, delay: 5), .init(color: 2, delay: 20), .init(color: 3, delay: 40)
])
