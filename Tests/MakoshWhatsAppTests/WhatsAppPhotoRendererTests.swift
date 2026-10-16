import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppPhotoRendererTests: XCTestCase {
  func testEXIFRotateCropMarksOrderAndNoUpscale() async throws {
    let source = try photoFixture(width: 80, height: 40, orientation: 6)
    defer { try? FileManager.default.removeItem(at: source) }
    let bytes = try Data(contentsOf: source)
    let base = try WhatsAppPhotoRenderer.render(source: source, recipe: .init(), mode: .standard)
    XCTAssertEqual(base.width, 40)
    XCTAssertEqual(base.height, 80)
    let mark = WhatsAppPhotoOperation.mark(
      .rect, [.init(x: 0.1, y: 0.1), .init(x: 0.8, y: 0.8)], .init(r: 1, g: 0, b: 0, a: 1), 0.04)
    let recipe = WhatsAppPhotoRecipe(operations: [
      mark, .crop(.init(x: 0, y: 0, width: 0.5, height: 1)), .rotate90,
    ])
    let result = try WhatsAppPhotoRenderer.render(source: source, recipe: recipe, mode: .hd)
    XCTAssertEqual(result.width, 80)
    XCTAssertEqual(result.height, 20)
    XCTAssertNotEqual(result.finalJPEG, base.finalJPEG)
    XCTAssertEqual(try Data(contentsOf: source), bytes)
    let plain = try WhatsAppPhotoRenderer.render(
      source: source,
      recipe: .init(operations: [.crop(.init(x: 0, y: 0, width: 0.5, height: 1)), .rotate90]),
      mode: .hd)
    XCTAssertNotEqual(result.finalJPEG, plain.finalJPEG, "Marks must be baked before crop/rotation")
  }
  func testStandardHDAndJPEGMetadataRemoval() async throws {
    let source = try photoFixture(width: 5000, height: 1000, orientation: 1)
    defer { try? FileManager.default.removeItem(at: source) }
    for (mode, edge) in [(WhatsAppPhotoMode.standard, 1600), (.hd, 4096)] {
      let result = try WhatsAppPhotoRenderer.render(source: source, recipe: .init(), mode: mode)
      XCTAssertEqual(result.width, edge)
      XCTAssertEqual(result.height, edge / 5)
      let decoded = try XCTUnwrap(CGImageSourceCreateWithData(result.finalJPEG as CFData, nil))
      XCTAssertEqual(CGImageSourceGetType(decoded) as String?, UTType.jpeg.identifier)
      let properties = try XCTUnwrap(
        CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [String: Any])
      XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
      let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
      XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
      XCTAssertTrue((properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)
    }
  }
}
func photoFixture(width: Int = 80, height: Int = 40, orientation: Int = 1) throws -> URL {
  let ctx = try XCTUnwrap(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
  let image = try XCTUnwrap(ctx.makeImage())
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".jpg")
  let dest = try XCTUnwrap(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(
    dest, image,
    [
      kCGImagePropertyOrientation: orientation,
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE_SYNTHETIC_SOURCE"],
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 50, kCGImagePropertyGPSLongitude: 20,
      ],
    ] as CFDictionary)
  XCTAssertTrue(CGImageDestinationFinalize(dest))
  return url
}
