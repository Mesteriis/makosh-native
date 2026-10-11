import XCTest
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

final class TelegramUploadVideoCoverPaintingTests: XCTestCase {
    // The reference binds physical A/E/L keys, so tools also work when a
    // non-Latin keyboard layout is active; unrelated keys keep normal routing.
    func testPhysicalToolKeysToggleDrawArrowAndSelectEraser() {
        typealias Tool = TelegramUploadVideoCoverPainting.Tool
        XCTAssertEqual(Tool.draw.selectingShortcut(keyCode: 0), .arrow)
        XCTAssertEqual(Tool.arrow.selectingShortcut(keyCode: 0), .draw)
        XCTAssertEqual(Tool.erase.selectingShortcut(keyCode: 0), .arrow)
        XCTAssertEqual(Tool.draw.selectingShortcut(keyCode: 37), .arrow)
        XCTAssertEqual(Tool.arrow.selectingShortcut(keyCode: 37), .draw)
        XCTAssertEqual(Tool.erase.selectingShortcut(keyCode: 37), .draw)
        XCTAssertEqual(Tool.arrow.selectingShortcut(keyCode: 14), .erase)
        XCTAssertNil(Tool.draw.selectingShortcut(keyCode: 1))
    }
    // Breaks caught: lost whole-stroke undo, redo surviving a new stroke, or a
    // cancelled value-copy changing the accepted painting.
    func testEditingCopyRetainsUndoHistoryAndDiscardsRedoWithoutMutatingAcceptedPainting() throws {
        let first = try stroke(.draw, [(0.1, 0.2), (0.9, 0.2)])
        let second = try stroke(.erase, [(0.5, 0.1), (0.5, 0.9)])
        var accepted = TelegramUploadVideoCoverPainting()
        accepted.append(first); accepted.append(second); accepted.undo()
        XCTAssertEqual(accepted.strokes, [first]); XCTAssertTrue(accepted.canRedo)
        var editing = accepted.editingCopy()
        XCTAssertFalse(editing.canRedo); XCTAssertTrue(editing.canUndo)
        editing.undo(); XCTAssertTrue(editing.strokes.isEmpty)
        editing.redo(); XCTAssertEqual(editing.strokes, [first])
        editing.undo(); editing.append(second); editing.redo()
        XCTAssertEqual(editing.strokes, [second])
        XCTAssertEqual(accepted.strokes, [first]); XCTAssertTrue(accepted.canRedo)
    }

    // Erasing must reveal the original pixels rather than make a black/clear
    // hole in the JPEG; strokes added afterwards must remain visible.
    func testEraserOnlyClearsPaintLayerAndLaterStrokesRemainVisible() throws {
        var painting = TelegramUploadVideoCoverPainting()
        painting.append(try stroke(.draw, [(0.1, 0.5), (0.9, 0.5)], width: 12))
        painting.append(try stroke(.erase, [(0.5, 0.1), (0.5, 0.9)], width: 20))
        var image = try TelegramUploadVideoCoverTransform().render(whiteImage(), crop: unit, painting: painting)
        try assertPixel(image, x: 25, y: 50, white: false)
        try assertPixel(image, x: 50, y: 50, white: true)
        try assertPixel(image, x: 50, y: 20, white: true)
        painting.append(try stroke(.draw, [(0.5, 0.4), (0.5, 0.6)], width: 4))
        image = try TelegramUploadVideoCoverTransform().render(whiteImage(), crop: unit, painting: painting)
        try assertPixel(image, x: 50, y: 50, white: false)
    }

    // Arrow is a straight first-to-last shaft, with two 45-degree head legs.
    // A diagonal whose Euclidean length exceeds the threshold is still too
    // short when neither axis exceeds 1.5 brush widths.
    func testArrowUsesEndpointsAndStrictAxisThresholdAndClickHasNoDot() throws {
        var painting = TelegramUploadVideoCoverPainting()
        painting.append(try stroke(.arrow, [(0.2, 0.5), (0.5, 0.1), (0.8, 0.5)], width: 8))
        let image = try TelegramUploadVideoCoverTransform().render(whiteImage(), crop: unit, painting: painting)
        try assertPixel(image, x: 50, y: 50, white: false)
        try assertPixel(image, x: 67, y: 37, white: false)
        try assertPixel(image, x: 67, y: 63, white: false)
        try assertPixel(image, x: 50, y: 10, white: true)
        var short = TelegramUploadVideoCoverPainting()
        short.append(try stroke(.arrow, [(0.2, 0.2), (0.35, 0.35)], width: 10))
        short.append(try stroke(.draw, [(0.5, 0.5)], width: 10))
        short.append(try stroke(.erase, [(0.7, 0.7)], width: 10))
        let empty = try TelegramUploadVideoCoverTransform().render(whiteImage(), crop: unit, painting: short)
        try assertPixel(empty, x: 27, y: 27, white: true)
        try assertPixel(empty, x: 50, y: 50, white: true)
        XCTAssertTrue(short.canUndo)
    }

    // Wrong inverse axes would place pointer strokes elsewhere after rotation
    // or mirroring; literal target coordinates cover all eight states.
    func testPointerMappingAndPaintStayRegisteredAcrossAllOrientations() throws {
        let points: [CGPoint] = [.init(x: 0.2, y: 0.3), .init(x: 0.3, y: 0.8),
            .init(x: 0.8, y: 0.7), .init(x: 0.7, y: 0.2)]
        let flipped: [CGPoint] = [.init(x: 0.8, y: 0.3), .init(x: 0.7, y: 0.8),
            .init(x: 0.2, y: 0.7), .init(x: 0.3, y: 0.2)]
        var painting = TelegramUploadVideoCoverPainting()
        painting.append(try stroke(.draw, [(0.15, 0.3), (0.25, 0.3)], width: 6))
        for mirror in [false, true] {
            var transform = TelegramUploadVideoCoverTransform()
            if mirror { transform.flipHorizontally() }
            for turn in 0..<4 {
                let expected = (mirror ? flipped : points)[turn]
                let mapped = transform.sourcePoint(from: expected)
                XCTAssertEqual(mapped.x, 0.2, accuracy: 0.000001)
                XCTAssertEqual(mapped.y, 0.3, accuracy: 0.000001)
                let image = try transform.render(whiteImage(), crop: unit, painting: painting)
                try assertPixel(image, x: Int((expected.x * 100).rounded()), y: Int((expected.y * 100).rounded()), white: false)
                try assertPixel(image, x: 50, y: 50, white: true)
                transform.rotate()
            }
        }
    }

    // The stage/export boundary must carry the accepted painting into the
    // cropped JPEG without replacing the authenticated original source.
    func testStagedJPEGIncludesPaintingAtScaledWidthAfterCrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try whiteImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
        defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
        var painting = TelegramUploadVideoCoverPainting()
        painting.append(try stroke(.draw, [(0.1, 0.3), (0.9, 0.3)], width: 10, canvas: CGSize(width: 200, height: 200)))
        let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), painting: painting)
        defer { try? TelegramUploadVideoCoverIO.discardCover(cover) }
        XCTAssertEqual(cover.width, 50); XCTAssertEqual(cover.height, 50)
        let image = try await TelegramUploadVideoCoverIO.preview(cover).image
        try assertPixel(image, x: 25, y: 30, white: false)
        try assertPixel(image, x: 25, y: 24, white: true)
        XCTAssertEqual(try Data(contentsOf: selection.file.url), original)
    }

    func testInvalidBrushGeometryIsRejectedBeforeRendering() throws {
        XCTAssertThrowsError(try stroke(.draw, [(Double.nan, 0.1), (0.2, 0.2)]))
        XCTAssertThrowsError(try stroke(.draw, [(0, 0), (1, 1)], width: .infinity))
        XCTAssertThrowsError(try stroke(.draw, [(0, 0), (1, 1)], canvas: .zero))
        XCTAssertThrowsError(try stroke(.draw, [(0, 0), (1, 1)], width: .greatestFiniteMagnitude))
        XCTAssertThrowsError(try stroke(.draw, [(0, 0), (1, 1)], canvas: CGSize(width: CGFloat.leastNonzeroMagnitude, height: 100)))
    }

    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private func stroke(_ tool: TelegramUploadVideoCoverPainting.Tool, _ points: [(Double, Double)],
                        width: CGFloat = 6, canvas: CGSize = CGSize(width: 100, height: 100)) throws -> TelegramUploadVideoCoverPainting.Stroke {
        try .init(tool: tool, points: points.map { CGPoint(x: $0.0, y: $0.1) }, rgb: 0, width: width, canvasSize: canvas)
    }
    private func whiteImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        return try XCTUnwrap(context.makeImage())
    }
    private func assertPixel(_ image: CGImage, x: Int, y: Int, white: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertTrue(bytes.prefix(3).allSatisfy { white ? $0 > 220 : $0 < 35 }, "pixel(\(x),\(y))=\(bytes), white=\(white)", file: file, line: line)
        XCTAssertEqual(bytes[3], 255, file: file, line: line)
    }
}
