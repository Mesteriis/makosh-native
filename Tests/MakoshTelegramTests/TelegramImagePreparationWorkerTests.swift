import XCTest
import CoreGraphics
import ImageIO
@testable import MakoshApp
@testable import MakoshTelegram
import MakoshCore

@MainActor final class TelegramImagePreparationWorkerTests: XCTestCase {
    func testPastedImageAndWorkerPNGEncodingRoundTrip() async throws {
        let bytes = try png()
        let images = try await TelegramVideoCoverImageInput.adding(.bytes(bytes), to: .init(),
            canvasSize: .init(width: 320, height: 320), imageSize: .init(width: 640, height: 640))
        let item = try XCTUnwrap(images.items.first)
        let encoded = try await BackgroundWork.run {
            XCTAssertFalse(Thread.isMainThread)
            return try TelegramVideoCoverImageInput.encodedPNG(item)
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 64)
    }
    func testAvatarPreparationUsesImmutableWorkerInput() async throws {
        let data = try png(), source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let preview = TelegramImagePreview(image: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let photo = try await BackgroundWork.run {
            XCTAssertFalse(Thread.isMainThread)
            return try TelegramAvatarPhoto.prepare(preview: preview, crop: .init(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertTrue(photo.isValid)
        XCTAssertEqual(photo.preview.image.width, 64)
    }
    func testCancelledWallpaperCleanupStillRemovesOnlyInstalledAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-wallpaper-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try png()
        let name = try await TelegramWallpaperFiles.installInBackground(data, pattern: true, directory: root)
        let restored = try await BackgroundWork.run { try TelegramWallpaperFiles.loadPattern(name, directory: root) }
        XCTAssertEqual(restored, data)
        let cleanup = Task { try await TelegramWallpaperFiles.discardInstalled(name, directory: root) }
        cleanup.cancel(); try await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage()), bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
