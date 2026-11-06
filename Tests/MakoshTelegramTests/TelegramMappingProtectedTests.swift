import Postbox
import XCTest
@testable import MakoshTelegram

final class TelegramMappingProtectedTests: XCTestCase {
    func testCopyProtectedSecretMediaAndProtectedChatsAreProtected() {
        XCTAssertFalse(telegramMessageIsProtected(flags: [.Incoming], containsSecretMedia: false, chatCopyProtected: false))
        XCTAssertTrue(telegramMessageIsProtected(flags: [.Incoming, .CopyProtected], containsSecretMedia: false, chatCopyProtected: false))
        XCTAssertTrue(telegramMessageIsProtected(flags: [], containsSecretMedia: true, chatCopyProtected: false))
        XCTAssertTrue(telegramMessageIsProtected(flags: [], containsSecretMedia: false, chatCopyProtected: true))
    }

    func testAttachmentsInheritTheMessageFlag() {
        let attachment = TelegramAttachment(
            id: "a", kind: .file, name: "Договор.pdf", byteCount: 1, mimeType: nil, hasPreview: false, canDownload: true)
        var message = TelegramMessage(id: "1:0:1", date: .now, text: "", author: "Иван", isOutgoing: false, delivery: .sent)
        message.attachments = [attachment]
        XCTAssertFalse(message.isProtected)
        XCTAssertFalse(message.attachments[0].isProtected)
        message.markProtected()
        XCTAssertTrue(message.isProtected)
        XCTAssertTrue(message.attachments[0].isProtected)
    }
}
