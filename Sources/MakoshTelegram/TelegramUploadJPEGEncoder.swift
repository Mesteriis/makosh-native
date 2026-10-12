import Foundation
import CoreGraphics
import MakoshJPEGControl

enum TelegramUploadJPEGEncoder {
    static func encode(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 2560, height <= 2560 else { return nil }
        let stride = (width * 4 + 15) & ~15
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return nil }
        var output: UnsafeMutablePointer<UInt8>?, length = 0
        guard makosh_jpeg_encode_rgbx75(pixels.assumingMemoryBound(to: UInt8.self), stride * height,
            UInt32(width), UInt32(height), stride, &output, &length) != 0, let output else { return nil }
        defer { free(output) }
        return Data(bytes: output, count: length)
    }
}
