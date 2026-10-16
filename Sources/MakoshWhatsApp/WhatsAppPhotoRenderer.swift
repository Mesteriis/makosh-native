import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// MIT-adapted operation order/geometry from pinned WhatsApp Zen PhotoEditor.
/// Image work is called only by the concrete background photo actor.
public enum WhatsAppPhotoRenderer {
  public static func validateDimensions(width: Int, height: Int) throws {
    guard width > 0, height > 0, width <= 40_000_000, height <= 40_000_000,
      width <= 40_000_000 / height
    else { throw WhatsAppFailure.invalid }
  }
  static func dimensions(source: URL) throws -> (Int, Int) {
    guard
      let src = CGImageSourceCreateWithURL(
        source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(src) == 1,
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = props[kCGImagePropertyPixelWidth] as? Int,
      let h = props[kCGImagePropertyPixelHeight] as? Int
    else { throw WhatsAppFailure.invalid }
    try validateDimensions(width: w, height: h)
    return (w, h)
  }
  public static func render(source: URL, recipe: WhatsAppPhotoRecipe, mode: WhatsAppPhotoMode)
    throws -> WhatsAppPhotoRenderResult
  {
    precondition(!Thread.isMainThread)
    try recipe.validate()
    try Task.checkCancellation()
    let (w, h) = try dimensions(source: source)
    let limit = mode == .standard ? 1600 : 4096
    guard
      let src = CGImageSourceCreateWithURL(
        source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      var image = CGImageSourceCreateThumbnailAtIndex(
        src, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: min(limit, max(w, h)),
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw WhatsAppFailure.invalid }
    for operation in recipe.operations {
      try Task.checkCancellation()
      switch operation {
      case .crop(let r):
        let rect = CGRect(
          x: r.x * Double(image.width), y: r.y * Double(image.height),
          width: r.width * Double(image.width), height: r.height * Double(image.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
          throw WhatsAppFailure.invalid
        }
        image = cropped
      case .rotate90:
        let ctx = try context(width: image.height, height: image.width)
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = ctx.makeImage() else { throw WhatsAppFailure.invalid }
        image = rotated
      case .mark(let kind, let points, let color, let fraction):
        let ctx = try context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        let width = fraction * Double(max(image.width, image.height))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(red: color.r, green: color.g, blue: color.b, alpha: color.a))
        func pixel(_ p: WhatsAppPhotoPoint) -> CGPoint {
          .init(x: p.x * Double(image.width), y: p.y * Double(image.height))
        }
        let first = pixel(points[0])
        let last = pixel(points.last!)
        if kind == .rect {
          ctx.stroke(
            CGRect(
              x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x),
              height: abs(last.y - first.y)))
        } else {
          ctx.move(to: first)
          if points.count == 1 {
            ctx.addLine(to: first)
          } else {
            for point in points.dropFirst() { ctx.addLine(to: pixel(point)) }
          }
          if kind == .arrow {
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(width * 4, 10)
            for delta in [-0.5, 0.5] {
              ctx.move(to: last)
              ctx.addLine(
                to: .init(
                  x: last.x - head * cos(angle + delta), y: last.y - head * sin(angle + delta)))
            }
          }
          ctx.strokePath()
        }
        guard let marked = ctx.makeImage() else { throw WhatsAppFailure.invalid }
        image = marked
      }
    }
    // Fresh destination properties deliberately exclude GPS/EXIF/source metadata.
    let data = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw WhatsAppFailure.invalid }
    CGImageDestinationAddImage(
      dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw WhatsAppFailure.invalid }
    return .init(finalJPEG: data as Data, width: image.width, height: image.height)
  }
  private static func context(width: Int, height: Int) throws -> CGContext {
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw WhatsAppFailure.invalid }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx
  }
}
