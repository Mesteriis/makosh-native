import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import MakoshTelegram

final class TelegramUploadPhotoEligibilityTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func image(width: Int, height: Int, type: String = UTType.png.identifier,
                       frames: Int = 1, dpi: Int? = nil, verticalDPI: Int? = nil) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = verticalDPI ?? dpi
        }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, pixels, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func stage(_ data: Data, name: String = "synthetic.png") async throws -> TelegramUploadFile {
        let root = try directory(), source = root.appendingPathComponent(name)
        try data.write(to: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(file) }
        try FileManager.default.removeItem(at: source)
        return file
    }

    // Catches using the filename as image proof or rejecting an ordinary static JPEG/PNG.
    func testStaticImageBytesAreEligibleIndependentlyOfFilename() async throws {
        let png = try await stage(image(width: 40, height: 40), name: "opaque.document")
        let jpeg = try await stage(image(width: 80, height: 40, type: UTType.jpeg.identifier), name: "opaque.bin")
        let pngEligible = try await TelegramUploadPhotoEligibility.canPrepare(png)
        let jpegEligible = try await TelegramUploadPhotoEligibility.canPrepare(jpeg)
        XCTAssertTrue(pngEligible)
        XCTAssertTrue(jpegEligible)
    }

    // Catches a changed inclusive 40-point/10:1 boundary for an unscaled source, including reciprocal aspect.
    func testMinimumAndAspectBoundariesForUnscaledSource() async throws {
        let cases: [(Int, Int, Bool)] = [
            (40, 40, true), (39, 40, false), (40, 39, false),
            (400, 40, true), (401, 40, false), (40, 400, true), (40, 401, false)
        ]
        for (width, height, expected) in cases {
            let file = try await stage(image(width: width, height: height))
            let actual = try await TelegramUploadPhotoEligibility.canPrepare(file)
            XCTAssertEqual(actual, expected, "\(width)×\(height)")
        }
    }

    // Catches ignoring the source's logical size: reference options use NSImage.size, before JPEG normalization.
    func testHighDPISmallLogicalImageRemainsAnOriginalFile() async throws {
        let data = try image(width: 64, height: 64, dpi: 144)
        let logical = try XCTUnwrap(NSImage(data: data)).size
        XCTAssertEqual(logical.width, 32, accuracy: 0.01)
        XCTAssertEqual(logical.height, 32, accuracy: 0.01)
        let file = try await stage(data)
        let actual = try await TelegramUploadPhotoEligibility.canPrepare(file)
        XCTAssertFalse(actual)
    }

    // Catches applying the 40-point option threshold to pixels instead of the frozen source.
    func testLowDPISourceWithFewerPixelsCanStillBePrepared() async throws {
        let data = try image(width: 32, height: 32, dpi: 36)
        let logical = try XCTUnwrap(NSImage(data: data)).size
        XCTAssertEqual(logical.width, 64, accuracy: 0.01)
        XCTAssertEqual(logical.height, 64, accuracy: 0.01)
        let file = try await stage(data)
        let actual = try await TelegramUploadPhotoEligibility.canPrepare(file)
        XCTAssertTrue(actual)
    }

    // Catches treating non-square DPI as a pixel aspect ratio and silently changing available modes.
    func testSourceLogicalAspectControlsPhotoEligibility() async throws {
        let cases: [(Int, Int, Int, Int, Bool)] = [
            (400, 40, 72, 144, false), // 400×20 points: too short and too wide.
            (40, 400, 144, 72, false), // 20×400 points: reciprocal rejection.
            (800, 40, 144, 72, true),  // 400×40 points: inclusive 10:1 boundary.
            (40, 800, 72, 144, true)   // 40×400 points: reciprocal boundary.
        ]
        for (width, height, dpi, verticalDPI, expected) in cases {
            let file = try await stage(image(width: width, height: height, dpi: dpi, verticalDPI: verticalDPI))
            let actual = try await TelegramUploadPhotoEligibility.canPrepare(file)
            XCTAssertEqual(actual, expected, "\(width)×\(height) @ \(dpi)/\(verticalDPI)")
        }
    }

    // Catches flattening GIF/WebP or a multi-frame image into the static-photo path.
    func testGIFWebPAndMultiFrameImageStayOutsideStaticPhotoPreparation() async throws {
        // Generated locally from synthetic pixels with Pillow12.3.0/libwebp1.6.0.
        // WEBP40×40,1frame,44bytes,SHA2565acc57b5b28d885223459dbbccab071ed1f87445450bfc43ba87f163d7e5f548.
        let webp = try XCTUnwrap(Data(base64Encoded: "UklGRiQAAABXRUJQVlA4TBcAAAAvJ8AJAAdQvEIVtP8BICH8P69G9D81AAA="))
        for data in [
            try image(width: 40, height: 40, type: UTType.gif.identifier),
            webp,
            try image(width: 40, height: 40, type: UTType.tiff.identifier, frames: 2)
        ] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 40)
            XCTAssertEqual(decoded.height, 40)
            let file = try await stage(data, name: "opaque.image")
            let actual = try await TelegramUploadPhotoEligibility.canPrepare(file)
            XCTAssertFalse(actual)
        }
    }

    // Catches trusting an image suffix, an undecodable image header, or an over-limit raw image.
    func testUnsupportedUndecodableAndOversizeRawBytesAreOrdinaryFalse() async throws {
        let png = try image(width: 40, height: 40)
        var oversize = png
        oversize.append(Data(count: 20 * 1024 * 1024 + 1 - oversize.count))
        for data in [Data("synthetic text".utf8), Data(png.prefix(32)), oversize] {
            let file = try await stage(data, name: "claimed.png")
            let actual = try await TelegramUploadPhotoEligibility.canPrepare(file)
            XCTAssertFalse(actual)
        }
    }

    // Catches accepting an arbitrary file URL or an already normalized photo as a raw stage.
    func testNonOwnedAndNonFileInputsThrow() async throws {
        let root = try directory(), source = root.appendingPathComponent("outside")
        let data = try image(width: 40, height: 40)
        try data.write(to: source)
        let fake = TelegramUploadFile(id: UUID(), name: "outside", size: Int64(data.count), mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: source, directory: root)
        do {
            _ = try await TelegramUploadPhotoEligibility.canPrepare(fake)
            XCTFail("Non-owned input must fail closed")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }

        let normalized = try await TelegramUploadFileIO.stage(source, mode: .photo)
        addTeardownBlock { try TelegramUploadFileIO.discard(normalized) }
        do {
            _ = try await TelegramUploadPhotoEligibility.canPrepare(normalized)
            XCTFail("Only a raw file stage is accepted")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    // Catches an owned path changed to a symlink or a different-sized payload before inspection.
    func testChangedOwnedStageThrowsInsteadOfBecomingUnsupported() async throws {
        let data = try image(width: 40, height: 40)
        let resized = try await stage(data)
        try (data + Data([0])).write(to: resized.url)
        do {
            _ = try await TelegramUploadPhotoEligibility.canPrepare(resized)
            XCTFail("Changed stage size must fail closed")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }

        let linked = try await stage(data)
        let root = try directory(), outside = root.appendingPathComponent("outside")
        try data.write(to: outside)
        try FileManager.default.removeItem(at: linked.url)
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: outside)
        do {
            _ = try await TelegramUploadPhotoEligibility.canPrepare(linked)
            XCTFail("Symlink stage must fail closed")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: outside), data)
    }

    // Catches swallowing cancellation as a routine unsupported file result.
    func testCancellationThrows() async throws {
        let file = try await stage(image(width: 40, height: 40))
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadPhotoEligibility.canPrepare(file)
        }
        do {
            _ = try await worker.value
            XCTFail("Cancelled eligibility must throw")
        } catch is CancellationError {}
    }
}
