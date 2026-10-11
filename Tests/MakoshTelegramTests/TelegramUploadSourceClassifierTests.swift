import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramUploadSourceClassifierTests: XCTestCase {
    private let item = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func facts(_ mime: String, image: TelegramUploadSourceFacts.ImageProbe = .notImage,
                       grouping: TelegramUploadSourceFacts.GroupingProbe = .ordinary) -> TelegramUploadSourceFacts {
        .init(itemID: item, role: .original, name: "source.bin", byteCount: 3,
              plaintextSHA256: digest, selectionMIME: mime, image: image, grouping: grouping)
    }

    // Catches replacing the ordered contribution/removal fold with a set or all-visual predicate.
    func testOrderedWebPRemovalAndLaterMediaContribution() {
        let png = facts("image/png", image: .decoded(width: 40, height: 40))
        let webp = facts("image/webp", image: .decoded(width: 320, height: 160))
        let doc = facts("application/pdf")
        let cases: [([TelegramUploadSourceFacts], [TelegramUploadPresentation])] = [
            ([], [.file]), ([png], [.media]), ([doc], [.file]), ([webp], [.file]),
            ([png, doc], [.media, .file]), ([doc, png], [.file, .media]),
            ([png, webp], [.file]), ([webp, png], [.media]),
            ([png, doc, webp], [.file]), ([png, doc, webp, png], [.file, .media]),
            ([png, png, doc, doc], [.media, .file])
        ]
        for (sources, want) in cases {
            XCTAssertEqual(TelegramUploadSourceClassifier.options(for: sources), want)
        }
    }

    // Catches contributing File for a failed/tiny/over-aspect image instead of skipping it.
    func testImageLogicalThresholdsSkipWithoutAddingFile() {
        let cases: [(TelegramUploadSourceFacts.ImageProbe, [TelegramUploadPresentation])] = [
            (.rejected, [.file]), (.decoded(width: 39, height: 40), [.file]),
            (.decoded(width: 40, height: 39), [.file]), (.decoded(width: 400, height: 40), [.media]),
            (.decoded(width: 401, height: 40), [.file]), (.decoded(width: 40, height: 400), [.media]),
            (.decoded(width: 40, height: 401), [.file])
        ]
        for (image, want) in cases {
            XCTAssertEqual(TelegramUploadSourceClassifier.options(for: [facts("image/png", image: image)]), want)
        }
        let small = facts("image/png", image: .decoded(width: 39, height: 40))
        XCTAssertEqual(TelegramUploadSourceClassifier.options(for: [small, facts("video/mp4")]), [.media])
        let webpRejected = facts("image/webp", image: .rejected)
        XCTAssertEqual(TelegramUploadSourceClassifier.options(for: [facts("video/mp4"), webpRejected]), [.media])
    }

    // Catches narrowing prefix/suffix selection rules to decoded payload kinds.
    func testSelectionMIMEOptionsRemainSeparateFromCanonicalPayload() {
        let cases: [(String, [TelegramUploadPresentation])] = [
            ("video/mp4", [.media]), ("video/mov", [.media]), ("video/m4v", [.media]),
            ("video/mp4-custom", [.media]), ("application/gif", [.media]),
            ("video/mkv", [.file]), ("video/quicktime", [.file]), ("audio/ogg", [.file])
        ]
        for (mime, want) in cases {
            XCTAssertEqual(TelegramUploadSourceClassifier.options(for: [facts(mime)]), want, mime)
        }
    }

    // Catches choosing Media merely because it exists among mixed options or ignoring asMedia.
    func testInitialPresentationRequiresAsMediaAndExactlyMediaOption() {
        let png = facts("image/png", image: .decoded(width: 40, height: 40))
        XCTAssertEqual(TelegramUploadSourceClassifier.initialPresentation(for: [png], asMedia: true), .media)
        XCTAssertEqual(TelegramUploadSourceClassifier.initialPresentation(for: [png], asMedia: false), .file)
        XCTAssertEqual(TelegramUploadSourceClassifier.initialPresentation(for: [png, facts("application/pdf")], asMedia: true), .file)
        XCTAssertEqual(TelegramUploadSourceClassifier.initialPresentation(for: [], asMedia: true), .file)
    }

    // Catches lost exact-WebP veto, mixed music grouping, recorder/Animated grouping, or singleton rejection.
    func testSourceGroupingMusicAndAnimationRules() {
        let doc = facts("application/pdf"), music = facts("audio/mpeg", grouping: .music)
        let voice = facts("audio/ogg", grouping: .voice), animation = facts("video/mp4", grouping: .animated)
        let webp = facts("image/webp", image: .decoded(width: 40, height: 40))
        let cases: [([TelegramUploadSourceFacts], TelegramUploadPresentation, Bool)] = [
            ([], .file, false), ([doc], .file, true), ([doc, doc], .file, true),
            ([doc], .media, false), ([facts("video/mp4")], .media, true),
            ([music], .file, true), ([music, music], .file, true), ([music, doc], .file, false),
            ([music], .media, false), ([voice], .file, false), ([animation], .file, false),
            ([webp], .file, false), ([webp, facts("video/mp4")], .media, false)
        ]
        for (sources, presentation, want) in cases {
            XCTAssertEqual(TelegramUploadSourceClassifier.allowsGrouping(for: sources, presentation: presentation), want)
        }
    }

    private var literal: [String: Any] {
        ["itemID": item.uuidString, "role": "original", "name": "source.bin", "byteCount": 3,
         "plaintextSHA256": digest, "selectionMIME": "image/png",
         "image": ["kind": "decoded", "width": 64, "height": 32], "grouping": "ordinary"]
    }

    private func decode(_ object: [String: Any]) throws -> TelegramUploadSourceFacts {
        try JSONDecoder().decode(TelegramUploadSourceFacts.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // Catches changing the independently specified eight-field wire contract or logical-size preservation.
    func testLiteralWireShapeRoundTripsWithoutGeneratedExpectations() throws {
        do {
            let value = try decode(literal)
            XCTAssertTrue(value.isValid)
            XCTAssertEqual(value.image, .decoded(width: 64, height: 32))
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            XCTAssertEqual(encoded as NSDictionary, literal as NSDictionary)
        } catch { XCTFail("Literal source facts must decode: \(error)") }
    }

    // Catches permissive defaults, ignored extensions or explicit-null downgrades at every required field.
    func testMissingExtraNullAndUnknownDiscriminatorsAreRefused() throws {
        for key in literal.keys {
            var missing = literal; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(missing), key)
            var null = literal; null[key] = NSNull()
            XCTAssertThrowsError(try decode(null), key)
        }
        var extra = literal; extra["recordID"] = item.uuidString
        XCTAssertThrowsError(try decode(extra))
        for (key, value) in [("role", "future"), ("grouping", "future")] {
            var object = literal; object[key] = value
            XCTAssertThrowsError(try decode(object))
        }
        let malformedImages: [[String: Any]] = [
            ["kind": "future"], ["kind": "notImage", "width": 1],
            ["kind": "rejected", "height": 1], ["kind": "decoded", "width": 1],
            ["kind": "decoded", "width": 1, "height": 1, "extra": true],
            ["kind": "decoded", "width": NSNull(), "height": 1]
        ]
        for image in malformedImages {
            var object = literal; object["image"] = image
            XCTAssertThrowsError(try decode(object))
        }
    }

    // Catches serializing invalid identities, names, bounds or image/MIME combinations into durable facts.
    func testInvalidFactsCannotEncodeOrDecode() throws {
        let mutations: [(String, Any)] = [
            ("itemID", "00000000-0000-0000-0000-000000000000"), ("name", "../bad.png"),
            ("name", " padded.png "), ("byteCount", -1), ("byteCount", Int64(4_294_967_297)),
            ("plaintextSHA256", digest.uppercased()), ("selectionMIME", "IMAGE/PNG"),
            ("selectionMIME", "image/png; charset=utf-8"),
            ("image", ["kind": "notImage"]),
            ("image", ["kind": "decoded", "width": 0, "height": 40]),
            ("selectionMIME", "application/octet-stream")
        ]
        for (key, value) in mutations {
            var object = literal; object[key] = value
            XCTAssertThrowsError(try decode(object), key)
        }
        for invalid in [
            facts("image/png"), facts("application/pdf", image: .rejected),
            facts("image/png", image: .decoded(width: .infinity, height: 40)),
            facts("image/png", image: .decoded(width: .nan, height: 40))
        ] {
            XCTAssertFalse(invalid.isValid)
            XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        }
        var upper = literal; upper["byteCount"] = Int64(4_294_967_296)
        do {
            let decoded = try decode(upper)
            XCTAssertTrue(decoded.isValid)
        }
        catch { XCTFail("Inclusive4GiB facts bound must remain valid: \(error)") }
    }
}
