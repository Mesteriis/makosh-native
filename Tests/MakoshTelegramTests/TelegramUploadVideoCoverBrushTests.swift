import XCTest
import CoreGraphics
@testable import MakoshTelegram

final class TelegramUploadVideoCoverBrushTests: XCTestCase {
    // Clicking the palette resets a saved/default thickness; pulling upward
    // increases it. A horizontal drag must still choose the continuous color.
    func testPaletteDragSelectsColorAndPullingUpChangesThickness() {
        var brush = TelegramUploadVideoCoverBrush(colorLocation: 0.5, weight: 0.22)
        XCTAssertEqual(brush.lineWidth, 5)
        brush.updatePicker(point: CGPoint(x: 96, y: 186), size: CGSize(width: 348, height: 200))
        XCTAssertEqual(brush.rgb, 0x3051E3); XCTAssertEqual(brush.lineWidth, 4)
        brush.updatePicker(point: CGPoint(x: 279, y: 60), size: CGSize(width: 348, height: 200))
        XCTAssertEqual(brush.rgb, 0); XCTAssertEqual(brush.lineWidth, 18)
        brush.updatePicker(point: CGPoint(x: 324, y: -500), size: CGSize(width: 348, height: 200))
        XCTAssertEqual(brush.rgb, 0xFFFFFF); XCTAssertEqual(brush.lineWidth, 18)
        brush.updatePicker(point: CGPoint(x: -100, y: 500), size: CGSize(width: 348, height: 200))
        XCTAssertEqual(brush.rgb, 0xEA2739); XCTAssertEqual(brush.lineWidth, 4)
    }

    func testContinuousGradientInterpolatesBetweenStops() {
        let brush = TelegramUploadVideoCoverBrush(colorLocation: 0.925, weight: 0.5)
        XCTAssertEqual(brush.rgb, 0x808080)
        XCTAssertEqual(brush.lineWidth, 10)
    }

    func testZoomedKnobRetainsHalfPointPrecisionOnRetinaDisplay() {
        let brush = TelegramUploadVideoCoverBrush(colorLocation: 0.5, weight: 3.0 / 7)
        XCTAssertEqual(brush.knobDiameter(displayScale: 2, pressed: true), 20.5)
        XCTAssertEqual(brush.knobDiameter(displayScale: 1, pressed: true), 20)
        XCTAssertEqual(brush.knobDiameter(displayScale: 2, pressed: false), 10)
    }
}
