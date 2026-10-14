import XCTest
import CoreImage
@testable import MakoshApp

final class TelegramQRLoginImageTests: XCTestCase {
    func testRenderedQRCodeDecodesToTheExactSyntheticLoginURL() throws {
        let value = "tg://login?token=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let image = try XCTUnwrap(telegramLoginQRImage(value))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(messages, [value])
    }
}
