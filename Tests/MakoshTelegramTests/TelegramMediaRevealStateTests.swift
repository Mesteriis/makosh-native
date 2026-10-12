import XCTest
@testable import MakoshTelegram

final class TelegramMediaRevealStateTests: XCTestCase {
    func testRevealIsExplicitAndCannotCarryIntoAnotherContextOrResourceVersion() {
        let hidden = TelegramAttachment(id: "synthetic-photo", kind: .photo, name: "Synthetic.png", byteCount: 100,
            mimeType: "image/png", hasPreview: true, canDownload: true, isSpoiler: true)
        let changed = TelegramAttachment(id: "synthetic-photo", kind: .photo, name: "Synthetic.png", byteCount: 200,
            mimeType: "image/png", hasPreview: true, canDownload: true, isSpoiler: true)
        let ordinary = TelegramAttachment(id: "ordinary-photo", kind: .photo, name: "Synthetic.png", byteCount: 100,
            mimeType: "image/png", hasPreview: true, canDownload: true)
        let context = UUID()
        var state = TelegramMediaRevealState()
        XCTAssertTrue(state.isHidden(hidden, contextID: context))
        XCTAssertFalse(state.isHidden(ordinary, contextID: context))
        state.reveal(hidden, contextID: context)
        XCTAssertFalse(state.isHidden(hidden, contextID: context))
        XCTAssertTrue(state.isHidden(hidden, contextID: UUID()))
        XCTAssertTrue(state.isHidden(changed, contextID: context))
        state = TelegramMediaRevealState()
        XCTAssertTrue(state.isHidden(hidden, contextID: context))
    }
}
