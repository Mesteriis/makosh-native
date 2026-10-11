import Foundation
import CoreGraphics

public struct TelegramUploadVideoCoverTransform: Equatable, Sendable {
    public private(set) var quarterTurns = 0
    public private(set) var isHorizontallyFlipped = false
    public init() {}
    public mutating func rotate() { quarterTurns = (quarterTurns + 1) % 4 }
    public mutating func flipHorizontally() { isHorizontallyFlipped.toggle() }

    public func imageSize(_ original: CGSize) -> CGSize {
        quarterTurns.isMultiple(of: 2) ? original : CGSize(width: original.height, height: original.width)
    }

    public func sourcePoint(from transformedPoint: CGPoint) -> CGPoint {
        let x = isHorizontallyFlipped ? 1 - transformedPoint.x : transformedPoint.x
        let y = transformedPoint.y
        switch quarterTurns {
        case 1: return CGPoint(x: 1 - y, y: x)
        case 2: return CGPoint(x: 1 - x, y: 1 - y)
        case 3: return CGPoint(x: y, y: 1 - x)
        default: return CGPoint(x: x, y: y)
        }
    }

    /// Crop coordinates start at the transformed image's top-left. Draw directly
    /// into the bounded cover, without allocating a second full-size bitmap.
    func render(_ image: CGImage, crop: CGRect, painting: TelegramUploadVideoCoverPainting = .init()) throws -> CGImage {
        let original = CGSize(width: image.width, height: image.height)
        let transformed = imageSize(original)
        let x = (crop.minX * transformed.width).rounded(), y = (crop.minY * transformed.height).rounded()
        let width = min(transformed.width - x, (crop.width * transformed.width).rounded())
        let height = min(transformed.height - y, (crop.height * transformed.height).rounded())
        guard width > 0, height > 0 else { throw TelegramUploadFileError.invalidImage }
        let bottom = y + height
        let scale = min(1, 320 / max(width, height))
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        guard let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TelegramUploadFileError.invalidImage
        }
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(targetWidth) / width, y: CGFloat(targetHeight) / height)
        context.translateBy(x: -x, y: -(transformed.height - bottom))
        context.translateBy(x: transformed.width / 2, y: transformed.height / 2)
        if isHorizontallyFlipped { context.scaleBy(x: -1, y: 1) }
        context.rotate(by: CGFloat(quarterTurns) * .pi / 2)
        context.translateBy(x: -original.width / 2, y: -original.height / 2)
        context.draw(image, in: CGRect(origin: .zero, size: original))
        context.translateBy(x: 0, y: original.height)
        context.scaleBy(x: 1, y: -1)
        painting.draw(in: context, imageSize: original)
        guard let output = context.makeImage() else { throw TelegramUploadFileError.invalidImage }
        return output
    }
}
