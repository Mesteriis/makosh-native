import XCTest
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

final class TelegramUploadVideoCoverImagesTests: XCTestCase {
    // Catches fitting inserts against source pixels instead of the displayed
    // canvas, and losing the reference's 50pt minimum fitting box for tiny images.
    func testInsertionFitsHalfCanvasAndCentersIncludingSmallImages() throws {
        var images = TelegramUploadVideoCoverImages()
        try images.append(.init(image: image(width: 800, height: 400)), canvasSize: CGSize(width: 320, height: 180))
        XCTAssertEqual(images.items[0].rect, CGRect(x: 80, y: 50, width: 160, height: 80))
        try images.append(.init(image: image(width: 20, height: 10)), canvasSize: CGSize(width: 552, height: 332))
        XCTAssertEqual(images.items[1].rect, CGRect(x: 251, y: 154, width: 50, height: 25))
        XCTAssertEqual(images.selectedID, images.items.last?.id)
    }

    // Undo restores selection and the entire ordered layer snapshot. A new
    // action must drop redo, while selecting alone must not create an undo step.
    func testLayerHistoryRestoresOrderSelectionAndClearsRedoOnNewEdit() throws {
        var images = TelegramUploadVideoCoverImages()
        try images.append(.init(image: image()), canvasSize: canvas)
        let first = try XCTUnwrap(images.selectedID)
        try images.append(.init(image: image()), canvasSize: canvas)
        let second = try XCTUnwrap(images.selectedID)
        images.select(first); images.bringSelectedToFront()
        XCTAssertEqual(images.items.map(\.id), [second, first])
        images.undo(); XCTAssertEqual(images.items.map(\.id), [first, second]); XCTAssertEqual(images.selectedID, first)
        images.redo(); XCTAssertEqual(images.items.map(\.id), [second, first])
        images.deleteSelected(); XCTAssertEqual(images.items.map(\.id), [second]); XCTAssertEqual(images.selectedID, second)
        images.undo(); XCTAssertEqual(images.items.map(\.id), [second, first]); XCTAssertEqual(images.selectedID, first)
        images.select(second); try images.move(second, by: CGSize(width: 20, height: 10), canvasSize: canvas)
        XCTAssertFalse(images.canRedo)
        images.undo(); XCTAssertEqual(images.items[0].rect, CGRect(x: 75, y: 75, width: 50, height: 50))
    }

    // The caller derives each live drag from its captured value, so many
    // pointer updates still become one undoable move and never compound deltas.
    func testDragSnapshotProducesOneUndoStepAndAllowsOffCanvasPlacement() throws {
        var initial = TelegramUploadVideoCoverImages()
        try initial.append(.init(image: image()), canvasSize: canvas)
        let id = try XCTUnwrap(initial.selectedID)
        var live = initial
        for x in [20.0, 60, 180] { live = initial; try live.move(id, by: CGSize(width: x, height: -80), canvasSize: canvas) }
        XCTAssertEqual(live.items[0].rect.minX, 255, accuracy: 0.000001)
        XCTAssertEqual(live.items[0].rect.minY, -5, accuracy: 0.000001)
        live.undo(); XCTAssertEqual(live.items[0].rect, initial.items[0].rect)
        live.undo(); XCTAssertTrue(live.items.isEmpty)
    }

    // Invalid imports/geometry must not partially change the current layers,
    // selection or undo history, and oversized sources fail before rendering.
    func testInvalidAndOverCapacityInsertionsAreAtomic() throws {
        var images = TelegramUploadVideoCoverImages()
        for _ in 0..<16 { try images.append(.init(image: image(width: 1, height: 1)), canvasSize: canvas) }
        let accepted = images
        XCTAssertThrowsError(try images.append(.init(image: image()), canvasSize: canvas))
        XCTAssertEqual(images, accepted)
        var empty = TelegramUploadVideoCoverImages()
        XCTAssertThrowsError(try empty.append(.init(image: image(width: 8193, height: 1)), canvasSize: canvas))
        XCTAssertThrowsError(try empty.append(.init(image: image()), canvasSize: .zero))
        XCTAssertTrue(empty.items.isEmpty); XCTAssertFalse(empty.canUndo)
        let id = try XCTUnwrap(images.selectedID)
        for rect in [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: -1, height: 1)] {
            XCTAssertThrowsError(try images.setRect(rect, for: id)); XCTAssertEqual(images, accepted)
        }
    }

    // Overlay coordinates belong to the transformed output canvas. Rotating or
    // mirroring the base must not rotate/mirror the overlay bitmap or its frame.
    func testOverlayPixelsRemainInOutputSpaceAcrossAllBaseOrientations() throws {
        var images = TelegramUploadVideoCoverImages()
        try images.append(.init(image: image(quadrants: true)), canvasSize: CGSize(width: 40, height: 20), imageSize: CGSize(width: 80, height: 40))
        try images.setRect(CGRect(x: 5, y: 5, width: 10, height: 10), for: XCTUnwrap(images.selectedID))
        for mirror in [false, true] {
            var transform = TelegramUploadVideoCoverTransform()
            if mirror { transform.flipHorizontally() }
            for _ in 0..<4 {
                let rendered = try transform.render(image(width: 80, height: 40), crop: unit, images: images)
                try assertColors(rendered, inPixels: CGRect(x: 10, y: 10, width: 20, height: 20))
                transform.rotate()
            }
        }
    }

    // Images sit above accepted paint; transparent pixels reveal it. Erasers
    // in the separate paint layer cannot clear inserted image pixels.
    func testLayerOrderAndTransparentPixelsComposeAbovePainting() throws {
        var images = TelegramUploadVideoCoverImages()
        try images.append(.init(image: image(width: 20, height: 20, rgb: 0xFF0000)), canvasSize: CGSize(width: 100, height: 100))
        let first = try XCTUnwrap(images.selectedID)
        try images.setRect(CGRect(x: 25, y: 25, width: 50, height: 50), for: first)
        try images.append(.init(image: image(width: 20, height: 20, rgb: 0x0000FF, transparentLeft: true)), canvasSize: CGSize(width: 100, height: 100))
        try images.setRect(CGRect(x: 25, y: 25, width: 50, height: 50), for: XCTUnwrap(images.selectedID))
        var paint = TelegramUploadVideoCoverPainting()
        paint.append(try .init(tool: .draw, points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)], rgb: 0, width: 20, canvasSize: CGSize(width: 100, height: 100)))
        var rendered = try TelegramUploadVideoCoverTransform().render(image(width: 100, height: 100), crop: unit, painting: paint, images: images)
        XCTAssertEqual(try color(rendered, x: 35, y: 50), "red")
        XCTAssertEqual(try color(rendered, x: 65, y: 50), "blue")
        images.select(first); images.bringSelectedToFront()
        rendered = try TelegramUploadVideoCoverTransform().render(image(width: 100, height: 100), crop: unit, painting: paint, images: images)
        XCTAssertEqual(try color(rendered, x: 65, y: 50), "red")
    }

    // The real staging boundary must retain overlays after the chosen source
    // and temporary snapshot disappear, and apply the final crop to them too.
    func testStagedJPEGIncludesFrozenOverlayAndCrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ bitmap: CGImage, name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, bitmap, nil); XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
        }
        let source = try write(image(width: 160, height: 80), name: "base.png")
        let overlaySource = try write(image(quadrants: true), name: "overlay.png")
        let original = try Data(contentsOf: source)
        let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
        defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
        let overlay = try await TelegramUploadVideoCoverIO.openSelection(overlaySource)
        var images = TelegramUploadVideoCoverImages()
        try images.append(overlay.preview, canvasSize: CGSize(width: 160, height: 80))
        try images.setRect(CGRect(x: 40, y: 20, width: 80, height: 40), for: XCTUnwrap(images.selectedID))
        try TelegramUploadVideoCoverIO.discardSelection(overlay)
        try FileManager.default.removeItem(at: overlaySource)
        let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), images: images)
        defer { try? TelegramUploadVideoCoverIO.discardCover(cover) }
        XCTAssertEqual(cover.width, 80); XCTAssertEqual(cover.height, 40)
        try assertColors(await TelegramUploadVideoCoverIO.preview(cover).image, inPixels: CGRect(x: 0, y: 0, width: 80, height: 40))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    // Literal results include the reference's unusual unconstrained horizontal
    // midpoint rule. All eight controls anchor opposite edges/centers correctly.
    func testEightResizeHandlesAndShiftGeometry() throws {
        typealias Handle = TelegramUploadVideoCoverImages.Handle
        let handles: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight, .top, .bottom, .left, .right]
        let locked: [CGRect] = [CGRect(x: 120, y: 70, width: 180, height: 90), CGRect(x: 100, y: 50, width: 220, height: 110), CGRect(x: 120, y: 60, width: 180, height: 90), CGRect(x: 100, y: 60, width: 210, height: 105), CGRect(x: 110, y: 70, width: 180, height: 90), CGRect(x: 90, y: 60, width: 220, height: 110), CGRect(x: 120, y: 65, width: 180, height: 90), CGRect(x: 100, y: 55, width: 220, height: 110)]
        let free: [CGRect] = [CGRect(x: 120, y: 70, width: 180, height: 90), CGRect(x: 100, y: 70, width: 220, height: 90), CGRect(x: 120, y: 60, width: 180, height: 110), CGRect(x: 100, y: 60, width: 220, height: 110), CGRect(x: 100, y: 70, width: 200, height: 90), CGRect(x: 100, y: 60, width: 200, height: 110), CGRect(x: 120, y: 40, width: 180, height: 140), CGRect(x: 100, y: 80, width: 220, height: 60)]
        for preserve in [true, false] {
            for (index, handle) in handles.enumerated() {
                var images = TelegramUploadVideoCoverImages()
                try images.append(.init(image: image()), canvasSize: CGSize(width: 400, height: 240))
                let id = try XCTUnwrap(images.selectedID)
                try images.setRect(CGRect(x: 100, y: 60, width: 200, height: 100), for: id)
                try images.resize(id, by: CGSize(width: 20, height: 10), handle: handle, preserveAspect: preserve)
                XCTAssertEqual(images.items[0].rect, (preserve ? locked : free)[index])
                images.undo(); XCTAssertEqual(images.items[0].rect, CGRect(x: 100, y: 60, width: 200, height: 100))
            }
        }
    }

    // A multi-file paste is one transaction and one undo action. A later
    // rejected image must not leave earlier members of the batch inserted.
    func testBatchPasteIsAtomicAndUsesOneUndoStep() throws {
        let first = TelegramImagePreview(image: try image())
        let second = TelegramImagePreview(image: try image(rgb: 0xFF0000))
        var images = TelegramUploadVideoCoverImages()
        try images.append([first, second], canvasSize: canvas)
        XCTAssertEqual(images.items.count, 2)
        images.undo(); XCTAssertTrue(images.items.isEmpty)
        images.redo(); XCTAssertEqual(images.items.count, 2)
        let accepted = images
        let oversized = TelegramImagePreview(image: try image(width: 8193, height: 1))
        XCTAssertThrowsError(try images.append([first, oversized], canvasSize: canvas))
        XCTAssertEqual(images, accepted)
    }

    // Deleted images remain in undo. Counting only visible layers would permit
    // repeatedly importing large assets to bypass the retained decoded budget.
    func testDecodedPixelBudgetIncludesUndoRetainedImages() throws {
        let large = TelegramImagePreview(image: try image(width: 8192, height: 2048))
        var images = TelegramUploadVideoCoverImages()
        try images.append(large, canvasSize: canvas)
        images.deleteSelected()
        try images.append(large, canvasSize: canvas)
        let accepted = images
        XCTAssertThrowsError(try images.append(large, canvasSize: canvas))
        XCTAssertEqual(images, accepted)
        images.undo(); XCTAssertTrue(images.items.isEmpty)
        images.undo(); XCTAssertEqual(images.items.count, 1)
    }

    // A long session retains the newest 64 edits while preserving redo order.
    func testBoundedHistoryKeepsLatestMovesAndCanRedoThem() throws {
        var images = TelegramUploadVideoCoverImages()
        try images.append(.init(image: image()), canvasSize: canvas)
        let id = try XCTUnwrap(images.selectedID)
        for _ in 0..<100 { try images.move(id, by: CGSize(width: 1, height: 0), canvasSize: canvas) }
        for _ in 0..<64 { images.undo() }
        XCTAssertEqual(images.items[0].rect.minX, 111)
        XCTAssertFalse(images.canUndo)
        for _ in 0..<64 { images.redo() }
        XCTAssertEqual(images.items[0].rect.minX, 175)
        XCTAssertFalse(images.canRedo)
    }

    private let canvas = CGSize(width: 200, height: 200)
    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private func image(width: Int = 50, height: Int = 50, rgb: UInt32 = 0xFFFFFF, quadrants: Bool = false, transparentLeft: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func fill(_ rgb: UInt32, _ rect: CGRect) {
            context.setFillColor(CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)); context.fill(rect)
        }
        fill(rgb, CGRect(x: 0, y: 0, width: width, height: height))
        if quadrants {
            fill(0xFF0000, CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
            fill(0x00FF00, CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
            fill(0x0000FF, CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
            fill(0xFFFF00, CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))
        }
        if transparentLeft { context.clear(CGRect(x: 0, y: 0, width: width / 2, height: height)) }
        return try XCTUnwrap(context.makeImage())
    }
    private func assertColors(_ image: CGImage, inPixels rect: CGRect) throws {
        for (x, y, expected) in [(0.25, 0.25, "red"), (0.75, 0.25, "green"), (0.25, 0.75, "blue"), (0.75, 0.75, "yellow")] {
            XCTAssertEqual(try color(image, x: Int(rect.minX + x * rect.width), y: Int(rect.minY + y * rect.height)), expected)
        }
    }
    private func color(_ image: CGImage, x: Int, y: Int) throws -> String {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if bytes[0] > 200, bytes[1] > 200, bytes[2] < 80 { return "yellow" }
        if bytes[0] > 200, bytes[1] < 80, bytes[2] < 80 { return "red" }
        if bytes[0] < 80, bytes[1] > 200, bytes[2] < 80 { return "green" }
        if bytes[0] < 80, bytes[1] < 80, bytes[2] > 200 { return "blue" }
        return "other"
    }
}
