import XCTest
@testable import MakoshFiles

final class FileActionsTests: XCTestCase {
    func testProtectedContentOffersNothing() {
        XCTAssertEqual(FileActions.available(protected: true, hasPaperless: true), [])
    }

    func testWithoutPaperlessTheOtherActionsRemain() {
        XCTAssertEqual(FileActions.available(protected: false, hasPaperless: false), [.forwardToChat, .forwardByMail, .askAI])
    }

    func testEverythingWithPaperless() {
        XCTAssertEqual(
            FileActions.available(protected: false, hasPaperless: true), [.sendToPaperless, .forwardToChat, .forwardByMail, .askAI])
        XCTAssertEqual(FileAction.sendToPaperless.title, "Отправить в Paperless…")
        XCTAssertEqual(FileAction.forwardToChat.title, "Отправить в чат…")
        XCTAssertEqual(FileAction.forwardByMail.title, "Отправить письмом…")
        XCTAssertEqual(FileAction.askAI.title, "Спросить ИИ…")
    }
}
