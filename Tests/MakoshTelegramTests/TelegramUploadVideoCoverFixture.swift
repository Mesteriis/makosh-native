import XCTest
import CoreGraphics
import ImageIO

func writeUploadVideoCoverFixture(_ url: URL) throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}
